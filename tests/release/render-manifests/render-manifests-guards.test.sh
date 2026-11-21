#!/usr/bin/env bash
#
# Three guards of the renderer that no other suite pinned one by one:
#
#   - digest_case_guard is called once per architecture. The existing upper-case
#     case uppercases both digests, so deleting either call left it green.
#     Here each architecture is uppercased alone and the message must name the
#     asset of that architecture.
#   - a tag that does not start with a digit after the leading v ("vBeta") is
#     refused by name, as a skipped product.
#   - the three transfer caps are fixed to their values in the real script. The
#     size cases lower the cap in a copy, which proves the mechanism and not the
#     number that ships.
#   - an empty signature is refused by the python layer itself. The size check
#     refuses a signature that is not 64 bytes before python runs, so the
#     ordinary cases never reach the verification loop with an empty file. Here
#     the size check is switched off in a copy, and the empty signature has to
#     be refused as a signature that does not verify.
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

# render <root>: the ordinary product row in a fresh root, exit status in $rc
# and output in $out.
render() {
	local root="$1"
	new_root "$root"
	generator_with "$root/scripts/release/render-manifests.sh" "$PODUP"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-manifests.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

# upper_only <asset>: sign a SHA256SUMS in which only that asset's digest is
# upper case.
upper_only() {
	awk -v a="$1" '$2 == a { print toupper($1) "  " $2; next } { print }' \
		"$RELEASES/Glyndor__podup/SHA256SUMS" > "$WORK/one.sums"
	resign "$WORK/one.sums" Glyndor/podup
}

for asset in podup-windows-x86_64.exe podup-windows-arm64.exe; do
	publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
	upper_only "$asset"
	render "$WORK/up-$asset"
	check "only $asset in upper case is refused (exit 3)" "3" "$rc"
	check "and the message names $asset" "1" "$(grep -c "for $asset in uppercase" <<<"$out")"
	check "and no manifest is written for $asset" "0" "$(find "$WORK/up-$asset/bucket" -name podup.json | wc -l)"
done

publish Glyndor/podup vBeta podup-windows-x86_64.exe podup-windows-arm64.exe
render "$WORK/beta"
check "a tag that starts with a letter after v is skipped (exit 3)" "3" "$rc"
check "and the message says it does not start with a digit" "1" "$(grep -c 'does not start with a digit' <<<"$out")"

# An empty signature, with the size check out of the way. The check measures the
# signature before python reads it, so it refuses a 0-byte file first and hides
# whether python would. The copy replaces that one comparison and nothing else;
# the two greps below fail the suite if the replacement did not take, because a
# copy that still carries the check would pass the refusal for the wrong reason.
# The genuine signature goes through the same copy and renders, so the refusal
# below comes from the empty signature and not from the fixture.
publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
new_root "$WORK/nosize"
generator_with "$WORK/nosize/scripts/release/render-manifests.sh" "$PODUP"
# shellcheck disable=SC2016 # the renderer's literal shell is under test
sed -i 's/\[ "\$sig_size" -eq "\$MAX_SIG_BYTES" \]/[ "$sig_size" -ge 0 ]/' \
	"$WORK/nosize/scripts/release/render-manifests.sh"
# shellcheck disable=SC2016 # the renderer's literal shell is under test
check "the copy no longer compares the signature size to MAX_SIG_BYTES" "0" \
	"$(grep -c -e '-eq "\$MAX_SIG_BYTES"' "$WORK/nosize/scripts/release/render-manifests.sh" || true)"
# shellcheck disable=SC2016 # the renderer's literal shell is under test
check "and the copy carries the replacement" "1" \
	"$(grep -c -e '\[ "\$sig_size" -ge 0 \]' "$WORK/nosize/scripts/release/render-manifests.sh" || true)"

rc=0
out="$( cd "$WORK/nosize" && "$WORK/nosize/scripts/release/render-manifests.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
check "the genuine signature renders through the copy (exit 0)" "0" "$rc"
check "and python reports the signature as verified" "1" "$(grep -c 'SHA256SUMS signature verified' <<<"$out")"

: > "$RELEASES/Glyndor__podup/SHA256SUMS.sig"
rm -f "$WORK/nosize/bucket/podup.json"
rc=0
out="$( cd "$WORK/nosize" && "$WORK/nosize/scripts/release/render-manifests.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
check "an empty signature is refused (exit 3)" "3" "$rc"
check "and python names it as a signature that does not verify" "1" \
	"$(grep -c 'does not verify against any configured release key' <<<"$out")"
check "and python does not report it as verified" "0" "$(grep -c 'SHA256SUMS signature verified' <<<"$out")"
check "and no manifest is written for it" "0" "$(find "$WORK/nosize/bucket" -name podup.json | wc -l)"

SCRIPT="$HERE_FIXTURE/../../../scripts/release/render-manifests.sh"
check "MAX_SUMS_BYTES ships as 4096" "MAX_SUMS_BYTES=4096" "$(grep '^MAX_SUMS_BYTES=' "$SCRIPT")"
check "MAX_SIG_BYTES ships as 64" "MAX_SIG_BYTES=64" "$(grep '^MAX_SIG_BYTES=' "$SCRIPT")"
check "MAX_ASSET_BYTES ships as 104857600" "MAX_ASSET_BYTES=104857600" "$(grep '^MAX_ASSET_BYTES=' "$SCRIPT")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
