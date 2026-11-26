#!/usr/bin/env bash
#
# Install an app from the published bucket with Scoop, as a user does, and update it from the version before.
#
# Usage: install-from-the-bucket.sh <app>      (run at the root of a checkout with the history of main, in Git Bash)
#
# check-manifests.sh reads the manifest with jq. This runs it:
#   1. the bucket is added, the app installed, the version Scoop reports is the one of the manifest, and the program
#      prints that version;
#   2. the manifest is put back to the commit before (found by previous-manifest.sh, copied over the file of the
#      bucket clone, which is what a machine that had not synced yet holds), installed, and the version it installed
#      is that commit's;
#   3. the current manifest is put back and `scoop update` is run, which has to leave the current version installed
#      and the program printing it.
# With no earlier version in the history there is nothing to update from: the script exits 3, which is not a pass.
# Any other failure exits 1.
#
# Environment: BUCKET (default glyndor), BUCKET_URL (default https://github.com/Glyndor/scoop-bucket) and BUCKET_DIR,
# the clone Scoop keeps of the bucket (default $HOME/scoop/buckets/$BUCKET).
set -euo pipefail

app="${1:?usage: install-from-the-bucket.sh <app>}"
bucket="${BUCKET:-glyndor}"
url="${BUCKET_URL:-https://github.com/Glyndor/scoop-bucket}"
dir="${BUCKET_DIR:-$HOME/scoop/buckets/$bucket}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="bucket/$app.json"

fail() {
	echo "::error::install-from-the-bucket: $*" >&2
	exit 1
}

installed() { scoop export 2>/dev/null | jq -r --arg a "$app" '[.apps[]? | select(.Name == $a) | .Version][0] // empty'; }
starts() { # the program prints the version it was asked for
	local want="$1" out
	out="$("$app" --version 2>&1)" || fail "$app does not start: $out"
	case "$out" in *"$want"*) ;; *) fail "$app prints \"$out\", which does not hold $want" ;; esac
}

scoop bucket add "$bucket" "$url" || fail "the bucket $bucket cannot be added"
[ -d "$dir" ] || fail "the clone of the bucket is not a folder: $dir"
current="$(git -C "$dir" rev-parse HEAD)" || fail "the clone of the bucket has no HEAD"

want="$(jq -r '.version // empty' "$dir/$file")" || want=""
[ -n "$want" ] || fail "the manifest $file of the bucket declares no version"

scoop install "$bucket/$app" || fail "scoop install $bucket/$app failed"
[ "$(installed)" = "$want" ] || fail "scoop installed $app $(installed), not the $want its manifest declares"
starts "$want"
echo "install-from-the-bucket: $app $want installs from $bucket and starts"

if ! prev="$(bash "$here/previous-manifest.sh" "$file")"; then
	echo "install-from-the-bucket: NOT VERIFIED: no earlier version of $file in the history, so an update cannot be tried" >&2
	exit 3
fi
sha="${prev%% *}"
before="${prev##* }"
git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$dir" fetch --quiet origin "$sha" || fail "the commit $sha of $file is not in the clone of the bucket"

scoop uninstall "$app" || fail "scoop uninstall $app failed"
git -C "$dir" checkout --quiet "$sha" -- "$file" || fail "the manifest of $sha cannot be put in the clone of the bucket"
scoop install "$bucket/$app" || fail "scoop install of the manifest of $sha failed"
[ "$(installed)" = "$before" ] || fail "the manifest of $sha installed $app $(installed), not its $before"
starts "$before"
echo "install-from-the-bucket: $app $before installed from the manifest of ${sha:0:7}"

git -C "$dir" checkout --quiet "$current" -- "$file" || fail "the current manifest cannot be put back in the clone of the bucket"
scoop update "$app" || fail "scoop update $app failed"
[ "$(installed)" = "$want" ] || fail "after scoop update $app is $(installed), not $want"
starts "$want"
echo "install-from-the-bucket: $app went from $before to $want with scoop update and starts"
