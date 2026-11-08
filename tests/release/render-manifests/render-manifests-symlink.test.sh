#!/usr/bin/env bash
#
# The renderer never writes through a symlink in bucket/. Redirecting straight
# into bucket/<name>.json followed a link there: the render said "rendered",
# bucket/ kept only the link, update.yml saw no change to commit and the bucket
# stayed frozen without a single red check. The renderer now refuses the link,
# names it, skips that product (exit 3) and leaves what the link points at
# untouched.
#
# The fixture both this file and its siblings need lives in
# tests/fixtures/release/render-fixture.sh.

set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

unset ATTEST_STUB_OUTCOME

# render <root>: a fresh root with the ordinary product row, exit status in
# $rc and output in $out.
render() {
	local root="$1"
	generator_with "$root/scripts/release/render-manifests.sh" "$PODUP"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-manifests.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe

# --- the control: a regular manifest is replaced in place ---------------------

new_root "$WORK/plain"
echo '{"version":"9.0.0"}' > "$WORK/plain/bucket/podup.json"
render "$WORK/plain"
check "control: a regular manifest is rendered over" "0" "$rc"
check "control: and carries the new version" "1" "$(grep -c '"version": "9.9.9"' "$WORK/plain/bucket/podup.json")"
check "control: and leaves no temporary file behind" "0" "$(find "$WORK/plain/bucket" -name '.render.*' | wc -l)"

# --- a manifest that is a symlink ------------------------------------------------
# The served version is read through the link first, so its target holds one.

new_root "$WORK/link"
echo '{"version":"9.0.0","outside":true}' > "$WORK/outside.json"
ln -s "$WORK/outside.json" "$WORK/link/bucket/podup.json"
render "$WORK/link"
check "a symlinked manifest skips the product (exit 3)" "3" "$rc"
check "and the message names the symlink" "1" "$(grep -c 'bucket/podup.json is a symlink' <<<"$out")"
check "and the file the link points at is untouched" '{"version":"9.0.0","outside":true}' "$(cat "$WORK/outside.json")"
check "and bucket/ still holds the link, not a rendered file" "1" "$([ -L "$WORK/link/bucket/podup.json" ] && echo 1 || echo 0)"
check "and no temporary file is left" "0" "$(find "$WORK/link/bucket" -name '.render.*' | wc -l)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
