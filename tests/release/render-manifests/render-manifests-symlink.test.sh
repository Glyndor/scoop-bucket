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
check "and no temporary file is left" "0" "$(find "$WORK/link" -name '.render.*' | wc -l)"

# run_directly <root>: the generator already in that root, run as it is. The
# controls below patch the generator first, and render() would copy the
# pristine one over the patch before running it.
run_directly() {
	local root="$1"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-manifests.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

# without_guard <root> <opening line>: the generator of that root with the `if`
# that opens with that line removed.
without_guard() {
	generator_with "$1/scripts/release/render-manifests.sh" "$PODUP"
	python3 -I - "$1/scripts/release/render-manifests.sh" "$2" <<'PY'
import re
import sys
path, opening = sys.argv[1], sys.argv[2]
text = open(path).read()
indent = re.escape(opening[:len(opening) - len(opening.lstrip())])
pattern = r'\n' + re.escape(opening) + r'\n(?:.*\n)*?' + indent + r'fi(?=\n)'
text, count = re.subn(pattern, "", text, count=1)
assert count == 1, opening
open(path, 'w').write(text)
PY
}

# --- a manifest that is a directory ----------------------------------------------
#
# `mv` moves the rendered file inside a directory and reports success, so the run
# said "rendered" while the bucket kept a directory where a manifest belongs.

new_root "$WORK/dir"
mkdir "$WORK/dir/bucket/podup.json"
render "$WORK/dir"
check "a manifest that is a directory skips the product (exit 3)" "3" "$rc"
check "and the message names the directory" "1" "$(grep -c 'bucket/podup.json is a directory' <<<"$out")"
check "and the directory is still there, holding nothing" "1 0" \
	"$([ -d "$WORK/dir/bucket/podup.json" ] && echo 1 || echo 0) $(find "$WORK/dir/bucket/podup.json" -mindepth 1 | wc -l)"
check "and no temporary file is left" "0" "$(find "$WORK/dir" -name '.render.*' | wc -l)"

new_root "$WORK/dirnoguard"
mkdir "$WORK/dirnoguard/bucket/podup.json"
without_guard "$WORK/dirnoguard" $'\tif [ -d "$target" ]; then'
run_directly "$WORK/dirnoguard"
check "control: without the check the run reports success" "0" "$rc"
check "control: and the rendered manifest lands inside the directory" "1" \
	"$(find "$WORK/dirnoguard/bucket/podup.json" -mindepth 1 | wc -l)"

# --- a bucket/ that is a symlink -------------------------------------------------
#
# Every manifest is written under bucket/. If that directory is a symlink, all of
# those writes land outside the repository and the bucket never changes.

new_root "$WORK/linkdir"
rm -rf "$WORK/linkdir/bucket"
mkdir -p "$WORK/outside"
ln -s "$WORK/outside" "$WORK/linkdir/bucket"
render "$WORK/linkdir"
check "a symlinked bucket/ stops the run (exit 1)" "1" "$rc"
check "and the message names the symlink" "1" "$(grep -c 'bucket/ is a symlink' <<<"$out")"
check "and nothing is written outside the repository" "0" "$(find "$WORK/outside" -mindepth 1 | wc -l)"
check "and bucket/ is still the link" "1" "$([ -L "$WORK/linkdir/bucket" ] && echo 1 || echo 0)"

new_root "$WORK/linkdirnoguard"
rm -rf "$WORK/linkdirnoguard/bucket"
mkdir -p "$WORK/outside2"
ln -s "$WORK/outside2" "$WORK/linkdirnoguard/bucket"
without_guard "$WORK/linkdirnoguard" "if [ -L \"\$root/bucket\" ]; then"
run_directly "$WORK/linkdirnoguard"
check "control: without the check the manifest is written outside the repository" "1" \
	"$([ -f "$WORK/outside2/podup.json" ] && echo 1 || echo 0)"

# --- the temporary is not created inside bucket/ ---------------------------------
#
# update.yml commits every untracked file under bucket/, so the template handed
# to mktemp is watched: the case says where the temporary is asked for and not
# only that the run ended clean.

mkdir -p "$WORK/mktemplog"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$WORK/mktemplog/mktemp" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/mktemplog/calls"
exec "$REAL_MKTEMP" "\$@"
SHIM
chmod +x "$WORK/mktemplog/mktemp"
new_root "$WORK/temp"
PATH="$WORK/mktemplog:$PATH" render "$WORK/temp"
check "a render with the temporary watched succeeds" "0" "$rc"
check "and the temporary is asked for at the root of the repository" "1" \
	"$(grep -cF "$WORK/temp/.render.XXXXXX" "$WORK/mktemplog/calls" || true)"
check "and no temporary is asked for inside bucket/" "0" \
	"$(grep -c '/bucket/' "$WORK/mktemplog/calls" || true)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
