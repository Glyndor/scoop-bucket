#!/usr/bin/env bash
#
# Every file under bucket/ must match exactly what scripts/release/render-manifests.sh
# emits: the same fields, the same shapes, nothing else. update.yml commits
# straight to main and there is no pull request between that commit and
# `scoop install`, so this is the last thing standing against a hand edit
# or a hijacked render. A hand edit can drop fields Scoop needs; a hijacked
# render can add a pre_install that runs an attacker's PowerShell on the
# user's machine. The allowlist is what stops the second one.
#
# Used to live twice -- once in the former ci.yml and once in update.yml, with a
# comment on each asking whoever edited one to keep the other in step.
# They were still byte-identical when this was written, so nothing had gone
# wrong yet; the duplication is the mechanism, not the symptom. update.yml's
# copy was the one that mattered, because it gates the commit before it
# lands on main and there is no review step between that commit and
# `scoop install`. Both now call this.
#
# The shape of a url is not the whole rule. A url also has to be this
# manifest's own product's release asset: the repository from the roster row
# that names it, and the tag the version in the manifest implies.
#
# Usage: check-manifests.sh [bucket-dir]   (default: bucket/ next to this repo)
set -euo pipefail
shopt -s nullglob

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bucket="${1:-$root/bucket}"

manifests=("$bucket"/*.json)
# An empty bucket must be an error, not a vacuous pass. A loop over nothing
# succeeds, and "every manifest is valid" would then be true of a bucket that
# serves nobody -- which is exactly how an emptied bucket reaches users.
if [ ${#manifests[@]} -eq 0 ]; then
	echo "::error::no manifests found under $bucket" >&2
	exit 1
fi

# The roster: one row per product, `repository|manifest|description|...`, read
# out of the table the renderer declares it in. PRODUCTS in
# scripts/release/render-manifests.sh is the only place a product is declared,
# and check-products-consistent.sh reads the same table: one list of products.
roster_file="$root/scripts/release/render-manifests.sh"
declare -A roster=()
while IFS='|' read -r product repo; do
	if [ -n "$product" ] && [ -n "$repo" ]; then
		roster["$product"]="$repo"
	fi
done < <(awk '/^PRODUCTS=\(/ { inside = 1; next }
                inside && /^\)/  { exit }
                inside           { print }' "$roster_file" 2>/dev/null \
	| sed -n 's/^[^"]*"\([^|]*\)|\([^|]*\)|.*/\2|\1/p')
# A roster that declares no product leaves nothing to bind a url to. That is an
# error, not a pass: a gate that cannot establish which repository a manifest
# may name cannot certify that it names the right one.
rosterknown="yes"
if [ ${#roster[@]} -eq 0 ]; then
	echo "::error::no PRODUCTS roster in $roster_file; the url of a manifest cannot be bound to its product" >&2
	exit 1
fi

# The fields scripts/release/render-manifests.sh emits, copied from it by hand. Nothing
# compares the two automatically, and running the generator here is not an
# option because it reads the releases over the network. What catches a
# divergence is the committed bucket: update.yml renders, this gate runs over
# the result before the commit, and tests/artifacts/check-manifests.test.sh runs it over
# the manifests already in the tree. A field added to the renderer and not to
# this list is refused the first time it is rendered, by name, rather than
# silently accepted. Anything outside these sets is a hand edit or a hijacked
# render, and the renderer is the only thing that should be writing here.
TOP_KEYS='["version","description","homepage","license","architecture"]'
ARCH_KEYS='["64bit","32bit","arm64"]'
SUB_KEYS='["url","hash","bin"]'
# The url must be a Glyndor release asset, not just a string that begins
# with the org prefix. A startswith check accepted ../attacker/payload/...:
# the prefix was text, and an HTTP client normalises `..` server-side, so the
# download actually came from the attacker's repo. The regex below pins
# every segment with literal dots and slashes, and each path-segment class
# requires at least one letter or digit so a dots-only segment like `..`
# does not slip through either.
#
# The regex fixes the shape, not the owner. Any Glyndor release fitted it, so
# a manifest could name another product's release and this gate had nothing to
# say. The owner is settled below, from the roster.
URL_RE='\Ahttps://github\.com/Glyndor/[A-Za-z0-9_.-]*[A-Za-z0-9][A-Za-z0-9_.-]*/releases/download/v[0-9A-Za-z]*[A-Za-z0-9][0-9A-Za-z.+-]*/[A-Za-z0-9_.-]*[A-Za-z0-9][A-Za-z0-9_.-]*\z'
HASH_RE='\A[0-9a-f]{64}\z'

for m in "${manifests[@]}"; do
	# The product this manifest publishes, and the repository its release
	# assets live in -- the row the renderer takes the repository from.
	product="$(basename "$m" .json)"
	repo="${roster[$product]-}"

	# JSON must parse. If it does not, there is no field to point at; the
	# message names the file and stops. Done first because every later check
	# feeds the file to jq as JSON.
	if ! jq -e . "$m" >/dev/null 2>&1; then
		echo "::error file=$m::$m is not valid JSON" >&2
		exit 1
	fi
	# One document. `jq -e .` accepts a stream of values, so two manifests
	# pasted one after the other would pass; a parser that reads a single
	# document rejects them.
	if [ "$(jq -s 'length' "$m")" != 1 ]; then
		echo "::error file=$m::$m must hold exactly one JSON document" >&2
		exit 1
	fi

	# A key that appears twice, at any depth. jq keeps the last value of a
	# repeated key and says nothing, so a manifest can carry two "version"
	# keys -- or two "url" keys under one architecture -- and every check
	# below would validate whichever one jq happened to keep. Which one the
	# consumer keeps is not defined either: PowerShell's ConvertFrom-Json,
	# which reads the manifest for Scoop, refuses the file outright, and a
	# reader that does not refuse it may take the other value. The renderer
	# never emits a repeated key, so one is a hand edit or a hijacked render.
	#
	# Python's object_pairs_hook sees the pairs before the object is built,
	# which is the only way to read a key that a value-based parser has
	# already dropped; jq cannot, because it only ever sees the value.
	# Checked before the field rules, which would otherwise describe a
	# document that no consumer ever installs.
	repeated="$(python3 -I - "$m" <<'PY'
import json
import sys


class Object(dict):
    """A JSON object that remembers the keys that appeared more than once."""

    def __init__(self, pairs):
        seen = set()
        repeated = []
        for key, _value in pairs:
            if key in seen and key not in repeated:
                repeated.append(key)
            seen.add(key)
        super().__init__(pairs)
        self.repeated = repeated


def duplicates(node, path):
    """Yield every (path, key) whose key appeared twice inside one object."""
    if isinstance(node, dict):
        for key in getattr(node, "repeated", ()):
            yield path, key
        for key, value in node.items():
            yield from duplicates(value, path + [key])
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from duplicates(value, path + [index])


def where(path):
    """Name the place a duplicated key sits, for the message."""
    if not path:
        return "at the top level"
    return "under " + " and ".join(
        "[%d]" % part if isinstance(part, int) else '"%s"' % part for part in path
    )


try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle, object_pairs_hook=Object)
except (OSError, ValueError) as error:
    sys.stderr.write("%s: %s\n" % (sys.argv[1], error))
    raise SystemExit(1)

for path, key in duplicates(document, []):
    print('has duplicate key "%s" %s' % (key, where(path)))
PY
	)" || {
		echo "::error file=$m::$m could not be checked for duplicate keys" >&2
		exit 1
	}
	if [ -n "$repeated" ]; then
		while IFS= read -r problem; do
			[ -n "$problem" ] || continue
			echo "::error file=$m::$m $problem" >&2
		done <<<"$repeated"
		exit 1
	fi

	# Collect every problem into a single jq invocation, then walk them in
	# bash. One pass per file keeps the gate cheap and the messages in one
	# place, with each message naming the file, the field and the shape the
	# renderer would have produced. Refusing at the first problem would mask
	# every later one; reporting them all turns the run into something a
	# reviewer can act on without rerunning the script four times.
	problems=$(jq -r --argjson top "$TOP_KEYS" \
	                    --argjson arch "$ARCH_KEYS" \
	                    --argjson sub "$SUB_KEYS" \
	                    --arg urlre "$URL_RE" \
	                    --arg hashre "$HASH_RE" \
	                    --arg repo "$repo" --arg product "$product" \
	                    --arg rosterknown "$rosterknown" '
		(.version | if type == "string" then . else "" end) as $version | [
			(if $repo == "" and $rosterknown == "yes" then "the PRODUCTS roster of scripts/release/render-manifests.sh has no row for \"\($product)\", so no release url is admissible for this manifest" else empty end),
			([keys[] | select(. as $k | ($top | index($k)) == null)] |
				if length > 0
				then "unexpected top-level key(s): " + (map("\"\(.)\"") | join(", "))
				else empty end),

			(if has("version") | not then "missing required top-level field \"version\""
			 elif (.version | type) != "string" then "field \"version\" must be a string"
			 elif (.version | length) == 0 then "field \"version\" must be a non-empty string"
			 else empty end),
			(if has("homepage") | not then "missing required top-level field \"homepage\""
			 elif (.homepage | type) != "string" then "field \"homepage\" must be a string"
			 else empty end),
			(if has("license") | not then "missing required top-level field \"license\""
			 elif (.license | type) != "string" then "field \"license\" must be a string"
			 else empty end),
			(if has("architecture") | not then "missing required top-level field \"architecture\""
			 elif (.architecture | type) != "object" then "field \"architecture\" must be a non-empty object"
			 elif (.architecture | length) == 0 then "field \"architecture\" must be a non-empty object"
			 else empty end),

			(try (.architecture | to_entries) catch empty | .[] |
				.key as $a | .value as $v |
				[
					(if ($v | type) != "object"
					 then "architecture \"\($a)\" must be an object, not \($v | type)"
					 else empty end),

					(if ($arch | index($a)) == null
					 then "architecture \"\($a)\" is not one of 64bit, 32bit, arm64"
					 else empty end),

					([$v | if type == "object" then keys[] else empty end
					   | select(. as $kk | ($sub | index($kk)) == null)] |
						if length > 0
						then "architecture \"\($a)\" has unexpected key(s): " + (map("\"\(.)\"") | join(", "))
						else empty end),

					(if ($v | type) != "object" then empty
					 elif ($v | has("url") | not) then "architecture \"\($a)\" missing required field \"url\""
					 elif ($v.url | type) != "string" then "architecture \"\($a)\" field \"url\" must be a string"
					 elif ($v.url | test($urlre) | not)
					 then "architecture \"\($a)\" field \"url\" must be a Glyndor release asset URL: https://github.com/Glyndor/<repo>/releases/download/<tag>/<asset>"
						else
						# The url has to be the release asset of the product
						# it publishes: the repository in the roster row, and
						# the tag the version in the manifest implies.
						("https://github.com/" + $repo + "/releases/download/v" + $version + "/") as $base
						| if $version == "" or $repo == "" or ($v.url | startswith($base)) then empty
						else ($v.url | split("/")) as $parts
						| (($parts[3] // "?") + "/" + ($parts[4] // "?")) as $named
						| if $named == $repo then
							"architecture \"\($a)\" field \"url\" must name the tag \"v\($version)\", the version this manifest declares; it names \"\($parts[7] // "?")\""
						  else
							"architecture \"\($a)\" field \"url\" must name the repository \"\($repo)\", the one this product releases from; it names \"\($named)\""
						  end
						end
					 end),

					(if ($v | type) != "object" then empty
					 elif ($v | has("hash") | not) then "architecture \"\($a)\" missing required field \"hash\""
					 elif ($v.hash | type) != "string" then "architecture \"\($a)\" field \"hash\" must be a string"
					 elif ($v.hash | test($hashre) | not)
						then "architecture \"\($a)\" field \"hash\" must match ^[0-9a-f]{64}$ exactly (no line feed or other character before or after)"
					 else empty end),

					(if ($v | type) != "object" then empty
					 elif ($v | has("bin") | not) then "architecture \"\($a)\" missing required field \"bin\""
					 elif (($v.bin | type) != "string" and ($v.bin | type) != "array")
						then "architecture \"\($a)\" field \"bin\" must be a string or an array"
					 elif ($v.bin | type) == "string" and ($v.bin | length) == 0
						then "architecture \"\($a)\" field \"bin\" must be a non-empty string"
					 elif ($v.bin | type) == "array" and ($v.bin | length) == 0
						then "architecture \"\($a)\" field \"bin\" must be a non-empty array"
					 elif ($v.bin | type) == "array" then
						# A Scoop bin entry is either a string (shim name) or a non-empty array of
						# strings in [exe, alias, args] form. A number, a boolean, or an empty inner
						# array is not a shim and has no place on the machine after scoop install.
						# Report each bad entry by index.
						$v.bin | to_entries[] |
							if (.value | type) == "string" and (.value | length) > 0 then empty
							elif (.value | type) == "array" and (.value | length) > 0 and (.value | all(.[]; type == "string" and length > 0)) then empty
							else "architecture \"\($a)\" bin entry \(.key) is not a non-empty string or an array of non-empty strings"
							end
					 else empty end)
				]
			)[]
		] | unique[]
	' "$m")

	if [ -n "$problems" ]; then
		while IFS= read -r problem; do
			[ -n "$problem" ] || continue
			echo "::error file=$m::$m $problem" >&2
		done <<<"$problems"
		exit 1
	fi

	echo "ok  $m"
done
