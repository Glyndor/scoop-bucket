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
# that names it, and the tag the version in the manifest implies. The other
# fields the renderer derives from that same row are held to it too: the
# homepage is that repository's page, the description is the row's, the
# licence is the one the renderer writes, each architecture downloads the asset
# the row names for it (and only an architecture the row publishes), and every
# `bin` entry is the pair the renderer writes -- the file the architecture
# downloads, and the product the shim is called after. The description is the
# text Scoop shows before anything is installed, and an asset of the same
# release that the row does not name has not been attested.
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

# Anything in the bucket that is neither a regular file nor a folder is refused:
# a manifest that is a symlink is read by the glob below like any other, so the
# gate would certify the link's target while the bucket serves a path that can
# be repointed.
links="$(find "$bucket" -mindepth 1 ! -type f ! -type d -printf '%P\n' | LC_ALL=C sort || true)"
if [ -n "$links" ]; then
	echo "::error::$bucket holds an entry that is not a regular file:" >&2
	printf '%s\n' "$links" | sed 's/^/  /' >&2
	exit 1
fi

# Only manifests live in the bucket. Scoop reads *.json, but the bucket serves
# every file in it, so a helper executable there is code the roster never listed.
stray="$(find "$bucket" -type f ! -iname '*.json' -printf '%P\n' | LC_ALL=C sort || true)"
if [ -n "$stray" ]; then
	echo "::error::$bucket holds a file that is not a manifest:" >&2
	printf '%s\n' "$stray" | sed 's/^/  /' >&2
	exit 1
fi

# The glob above reads bucket/<name>.json and nothing else, while Scoop reads a
# manifest in a subfolder and one whose extension is in capitals. A file the
# gate never opens is a file it cannot hold to its roster row, so it is refused
# by name. check-products-consistent.sh states the same definition.
odd="$(find "$bucket" -type f -iname '*.json' -printf '%P\n' | grep -Ev '^[^/]+\.json$' | LC_ALL=C sort || true)"
if [ -n "$odd" ]; then
	echo "::error::$bucket holds a file that is not <name>.json (directly in the bucket, lowercase extension):" >&2
	printf '%s\n' "$odd" | sed 's/^/  /' >&2
	exit 1
fi

# The roster: one row per product, `repository|manifest|description|...`, read
# out of the table the renderer declares it in. PRODUCTS in
# scripts/release/render-manifests.sh is the only place a product is declared,
# and check-products-consistent.sh reads the same table through the same
# reader, scripts/release/products.sh: one list of products, one grammar.
roster_file="$root/scripts/release/render-manifests.sh"
declare -A roster=()
declare -A roster_description=()
declare -A roster_asset_64=()
declare -A roster_asset_arm=()
rows="$(bash "$(dirname "${BASH_SOURCE[0]}")/../release/products.sh" "$roster_file")" || rows=""
while IFS='|' read -r repo product description asset_64 asset_arm; do
	if [ -n "$product" ] && [ -n "$repo" ]; then
		# A product declared twice is rendered twice, the second row over the
		# first, and which row this gate binds a manifest to would be whichever
		# came last. The renderer refuses it before it reads a release, by the
		# same words.
		if [ -n "${roster[$product]:-}" ]; then
			echo "::error::the PRODUCTS roster declares $product twice" >&2
			exit 1
		fi
		roster["$product"]="$repo"
		# The renderer reads the row with bash, which takes a backslash before
		# a double quote, a dollar sign, a backtick or another backslash as that
		# character; the table is read here as it is written, so the same
		# reading is applied to the one column that is compared as text.
		roster_description["$product"]="$(printf '%s' "$description" | sed -E 's/\\([\\"$`])/\1/g')"
		roster_asset_64["$product"]="$asset_64"
		roster_asset_arm["$product"]="$asset_arm"
	fi
done <<<"$rows"
# A roster that declares no product leaves nothing to bind a url to. That is an
# error, not a pass: a gate that cannot establish which repository a manifest
# may name cannot certify that it names the right one.
rosterknown="yes"
if [ ${#roster[@]} -eq 0 ]; then
	echo "::error::no PRODUCTS roster in $roster_file; the url of a manifest cannot be bound to its product, and neither can its homepage" >&2
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
# Every product published here is MIT: the renderer writes that literal for all
# of them, and tests/artifacts/check-manifests/check-manifests-binding.test.sh
# compares the two so that neither can change alone.
LICENSE='MIT'
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
	row_description="${roster_description[$product]-}"
	row_asset_64="${roster_asset_64[$product]-}"
	row_asset_arm="${roster_asset_arm[$product]-}"

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
	                    --arg description "$row_description" --arg license "$LICENSE" \
	                    --arg asset64 "$row_asset_64" --arg assetarm "$row_asset_arm" \
	                    --arg rosterknown "$rosterknown" '
		(.version | if type == "string" then . else "" end) as $version | [
			(if $repo == "" and $rosterknown == "yes" then "the PRODUCTS roster of scripts/release/render-manifests.sh has no row for \"\($product)\", so no release url or homepage is admissible for this manifest" else empty end),
			([keys[] | select(. as $k | ($top | index($k)) == null)] |
				if length > 0
				then "unexpected top-level key(s): " + (map("\"\(.)\"") | join(", "))
				else empty end),

			(if has("version") | not then "missing required top-level field \"version\""
			 elif (.version | type) != "string" then "field \"version\" must be a string"
			 elif (.version | length) == 0 then "field \"version\" must be a non-empty string"
			 else empty end),
			# The renderer always emits the description of the roster row, so a
			# manifest without one is a hand edit or a hijacked render.
			(if has("description") | not then "missing required top-level field \"description\""
			 elif (.description | type) != "string" then "field \"description\" must be a string"
			 elif (.description | length) == 0 then "field \"description\" must be a non-empty string"
			 elif $repo == "" then empty
			 elif .description != $description
			 then "field \"description\" must be exactly \($description | @json), the description of the PRODUCTS row of this product; it is \(.description | @json)"
			 else empty end),
			# The homepage is the repository the row names, and nothing else.
			# A string of any shape passed before, including a "javascript:"
			# one, which is a link the reader of the manifest would follow.
			# The value is printed with @json because it is attacker-supplied:
			# a newline in it would forge a line of the CI log.
			(if has("homepage") | not then "missing required top-level field \"homepage\""
			 elif (.homepage | type) != "string" then "field \"homepage\" must be a string"
			 elif $repo == "" then empty
			 elif .homepage != ("https://github.com/" + $repo)
			 then "field \"homepage\" must be exactly \"https://github.com/\($repo)\", the page of the product this manifest publishes; it is \(.homepage | @json)"
			 else empty end),
			(if has("license") | not then "missing required top-level field \"license\""
			 elif (.license | type) != "string" then "field \"license\" must be a string"
			 elif .license != $license
			 then "field \"license\" must be exactly \($license | @json), the licence the renderer writes; it is \(.license | @json)"
			 else empty end),
			(if has("architecture") | not then "missing required top-level field \"architecture\""
			 elif (.architecture | type) != "object" then "field \"architecture\" must be a non-empty object"
			 elif (.architecture | length) == 0 then "field \"architecture\" must be a non-empty object"
			 else empty end),

			(try (.architecture | to_entries) catch empty | .[] |
				.key as $a | .value as $v |
				# The file this architecture downloads: the last path segment of a
				# well-formed url. A `bin` entry that does not name exactly this
				# file points the shim somewhere else. It is bound to null when
				# the url is not a well-formed one, because then the url rule
				# below is the cause, and two causes for one field would only
				# blur it.
				(if ($v | type) == "object" and ($v.url | type) == "string" and ($v.url | test($urlre))
				 then ($v.url | split("/") | last)
				 else null end) as $asset |
				# The asset the PRODUCTS row names for this architecture, "-" when
				# the row publishes nothing for it. The renderer has no build to
				# write for 32bit, so the row has no slot for it.
				(if $a == "64bit" then $asset64 elif $a == "arm64" then $assetarm else "-" end) as $named |
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

					# Not every asset of a release is one the row vouches for: a
					# checksum file, a source tarball or an extra binary sits in the same
					# release and fits the url rule. The file this architecture downloads
					# is the one the row names for it.
					(if $asset == null or $repo == "" then empty
					 elif $named == "-"
					 then "architecture \"\($a)\" is not published by the PRODUCTS row of this product, which names no asset for it"
					 elif $asset != $named
					 then "architecture \"\($a)\" field \"url\" must download the asset \($named | @json), the one the PRODUCTS row names for it; it downloads \($asset | @json)"
					 else empty end),

					(if ($v | type) != "object" then empty
					 elif ($v | has("hash") | not) then "architecture \"\($a)\" missing required field \"hash\""
					 elif ($v.hash | type) != "string" then "architecture \"\($a)\" field \"hash\" must be a string"
					 elif ($v.hash | test($hashre) | not)
						then "architecture \"\($a)\" field \"hash\" must match ^[0-9a-f]{64}$ exactly (no line feed or other character before or after)"
					 else empty end),

					(if ($v | type) != "object" then empty
					 elif ($v | has("bin") | not) then "architecture \"\($a)\" missing required field \"bin\""
					 elif ($v.bin | type) != "array"
					 then "architecture \"\($a)\" field \"bin\" must be an array of [asset, alias] pairs"
					 elif ($v.bin | length) == 0
					 then "architecture \"\($a)\" field \"bin\" must be a non-empty array of [asset, alias] pairs"
					 else
						# The renderer writes one pair per architecture, and nothing
						# else: the file the architecture downloads, and the product
						# the shim is called after. A third element is the
						# [exe, alias, args] form Scoop accepts, and those
						# arguments are written into the shim the user runs. A
						# first element that is not the downloaded file points
						# the shim at another file, or at one outside the
						# install directory.
						$v.bin | to_entries[] |
							.key as $i | .value as $e |
							(if ($e | type) != "array"
							 then "architecture \"\($a)\" bin entry \($i) must be an [asset, alias] pair, not \($e | type)"
							 elif ($e | length) != 2
							 then "architecture \"\($a)\" bin entry \($i) must hold exactly two elements [asset, alias]; it holds \($e | length)"
							 elif ($e[0] | type) != "string" or ($e[1] | type) != "string"
							 then "architecture \"\($a)\" bin entry \($i) must hold two strings [asset, alias]"
							 elif ($e[0] | length) == 0 or ($e[1] | length) == 0
							 then "architecture \"\($a)\" bin entry \($i) must name a non-empty asset and a non-empty alias"
							 elif $asset != null and $e[0] != $asset
							 then "architecture \"\($a)\" bin entry \($i) names the executable \($e[0] | @json), but this architecture downloads \($asset | @json)"
							 elif $e[1] != $product
							 then "architecture \"\($a)\" bin entry \($i) names the alias \($e[1] | @json), but the shim of this manifest is named after the product, \($product | @json)"
							 else empty end)
					 end)
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
