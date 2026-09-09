#!/usr/bin/env bash
#
# Every file under bucket/ must match exactly what scripts/render-manifests.sh
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
# Usage: check-manifests.sh [bucket-dir]   (default: bucket/ next to this repo)
set -euo pipefail
shopt -s nullglob

bucket="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bucket}"

manifests=("$bucket"/*.json)
# An empty bucket must be an error, not a vacuous pass. A loop over nothing
# succeeds, and "every manifest is valid" would then be true of a bucket that
# serves nobody -- which is exactly how an emptied bucket reaches users.
if [ ${#manifests[@]} -eq 0 ]; then
	echo "::error::no manifests found under $bucket" >&2
	exit 1
fi

# The fields scripts/render-manifests.sh emits, copied from it by hand. Nothing
# compares the two automatically, and running the generator here is not an
# option because it reads the releases over the network. What catches a
# divergence is the committed bucket: update.yml renders, this gate runs over
# the result before the commit, and tests/check-manifests.test.sh runs it over
# the manifests already in the tree. A field added to the renderer and not to
# this list is refused the first time it is rendered, by name, rather than
# silently accepted. Anything outside these sets is a hand edit or a hijacked
# render, and the renderer is the only thing that should be writing here.
TOP_KEYS='["version","description","homepage","license","architecture"]'
ARCH_KEYS='["64bit","32bit","arm64"]'
SUB_KEYS='["url","hash","bin"]'
URL_PREFIX='https://github.com/Glyndor/'
HASH_RE='^[0-9a-f]{64}$'

for m in "${manifests[@]}"; do
	# JSON must parse. If it does not, there is no field to point at; the
	# message names the file and stops. Done first because every later check
	# feeds the file to jq as JSON.
	if ! jq -e . "$m" >/dev/null 2>&1; then
		echo "::error file=$m::$m is not valid JSON" >&2
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
	                    --arg urlprefix "$URL_PREFIX" \
	                    --arg hashre "$HASH_RE" '
		[
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
					 elif ($v.url | startswith($urlprefix) | not)
						then "architecture \"\($a)\" field \"url\" must start with " + $urlprefix
					 else empty end),

					(if ($v | type) != "object" then empty
					 elif ($v | has("hash") | not) then "architecture \"\($a)\" missing required field \"hash\""
					 elif ($v.hash | type) != "string" then "architecture \"\($a)\" field \"hash\" must be a string"
					 elif ($v.hash | test($hashre) | not)
						then "architecture \"\($a)\" field \"hash\" must match " + $hashre
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
							if (.value | type) == "string" then empty
							elif (.value | type) == "array" and (.value | length) > 0 and (.value | all(.[]; type == "string")) then empty
							else "architecture \"\($a)\" bin entry \(.key) is not a string or array of strings"
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
