#!/usr/bin/env bash
#
# Every file under bucket/ must be valid JSON carrying the fields Scoop needs:
# version, homepage and license, plus a url, a hash and a bin array for each
# declared architecture. A manifest missing any of them installs nothing and
# says something unhelpful on the user's machine.
#
# This existed twice -- once in ci.yml and once in update.yml, with a comment
# on each asking whoever edits one to keep the other in step. They were still
# byte-identical when this was written, so nothing had gone wrong yet; the
# duplication is the mechanism, not the symptom. The same shape had the apt
# keyring bootstrap living in four places, and by the time anyone looked, the
# order was wrong in all of them.
#
# update.yml's copy was the one that mattered: it gates the commit before it
# lands on main, and there is no pull request between that commit and
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

for m in "${manifests[@]}"; do
	jq -e '
	  (.version | type == "string" and (. | length > 0))
	  and (.homepage | type == "string")
	  and (.license | type == "string")
	  and (.architecture | type == "object" and (. | length > 0))
	  and (.architecture | to_entries | all(
	        .value.url and .value.hash and (.value.bin | type == "array")))
	' "$m" >/dev/null || {
		echo "::error file=$m::$m is not a valid, complete Scoop manifest" >&2
		exit 1
	}
	echo "ok  $m"
done
