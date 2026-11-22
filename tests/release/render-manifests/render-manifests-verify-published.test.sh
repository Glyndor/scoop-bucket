#!/usr/bin/env bash
#
# `render-manifests.sh --verify-published` reads the manifests already in bucket/
# against the signed SHA256SUMS of the release each url names. A render writes only
# digests it verified, but a manifest is a file a person can edit, and the digest in
# it was never read against the signed list again: the digest of an asset nobody
# signed passes the structural gate and the byte comparison alike, because the bytes
# behind the url really do have that digest.
#
# Each refusal below plants one fault in an otherwise good tree and says which
# check refused it. The accepted case runs first, on the manifest the renderer wrote
# itself, and the faults are applied to a copy of it.
#
# Requires: jq, python3 with cryptography.
set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

unset ATTEST_STUB_OUTCOME

SCRIPT_OF() { echo "$1/scripts/release/render-manifests.sh"; }

# verify <root>: the exit status in $rc, the output in $out.
verify() {
	rc=0
	out="$( cd "$1" && "$(SCRIPT_OF "$1")" --pubkey "$PUBKEY" --verify-published 2>&1 )" || rc=$?
}
said() { printf '%s\n' "$out" | grep -cF -- "$1" || true; }

# A tree whose bucket the renderer wrote from a published release.
good_tree() { # $1=root
	publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
	new_root "$1"
	generator_with "$(SCRIPT_OF "$1")" "$PODUP"
	run "$(SCRIPT_OF "$1")" "$1"
}
edit() { # $1=root $2=jq filter over bucket/podup.json
	jq "$2" "$1/bucket/podup.json" > "$1/edited.json"
	mv "$1/edited.json" "$1/bucket/podup.json"
}

good_tree "$WORK/ok"
check "the renderer wrote the manifest the cases start from" "9.9.9" "$(jq -r .version "$WORK/ok/bucket/podup.json")"
verify "$WORK/ok"
check "a manifest whose digests are the signed ones is accepted" "0" "$rc"
check "and says how many digests it read" "1" "$(said 'verified 2 published digest(s)')"

# The two architectures name one release, so it is read once: SHA256SUMS, its
# signature and the second signature are three transfers, not six.
reads() { grep -c -- "$1\$" "$WORK/curl.log" || true; }
rm -f "$WORK/curl.log"
CURL_STUB_LOG="$WORK/curl.log" verify "$WORK/ok"
check "two architectures of one release are accepted" "0" "$rc"
check "and SHA256SUMS of the release was fetched once" "1" "$(reads '/SHA256SUMS')"
check "and its Ed25519 signature was fetched once" "1" "$(reads '/SHA256SUMS.sig')"
check "and its second signature was asked for once" "1" "$(reads '/SHA256SUMS.mldsa65.sig')"
check "and nothing else was fetched" "3" "$(wc -l < "$WORK/curl.log")"

# --- a digest that is not the signed one ------------------------------------
good_tree "$WORK/digest"
edit "$WORK/digest" ".architecture[\"64bit\"].hash = \"$(printf 'e%.0s' {1..64})\""
verify "$WORK/digest"
check "a digest that is not the signed one is refused" "1" "$rc"
check "and the refusal is for the digest, naming the signed one" "1" "$(said "but the signed SHA256SUMS of Glyndor/podup v9.9.9 gives $H64 for podup-windows-x86_64.exe")"
check "and the architecture that was not edited is not reported" "0" "$(said 'architecture arm64 declares')"

# The second architecture reads the list the first one verified, and its own digest is
# still compared with it.
good_tree "$WORK/digest-second"
edit "$WORK/digest-second" ".architecture[\"arm64\"].hash = \"$(printf 'd%.0s' {1..64})\""
verify "$WORK/digest-second"
check "a digest of the architecture that reads the list again is refused" "1" "$rc"
check "and the refusal names the signed one for that architecture" "1" "$(said "architecture arm64 declares digest $(printf 'd%.0s' {1..64}), but the signed SHA256SUMS of Glyndor/podup v9.9.9 gives")"
check "and the architecture that was not edited is not reported" "0" "$(said 'architecture 64bit declares')"

# --- an asset the signed list does not carry ---------------------------------
# The release holds one more file, with a digest of its own that is the digest of its
# bytes, and the manifest points at it. Every local check and the byte comparison
# agree with that manifest; the signed list does not carry the file.
good_tree "$WORK/extra"
extra_digest="$(printf 'asset-evil.exe' | sha256sum | awk '{print $1}')"
edit "$WORK/extra" ".architecture[\"64bit\"].url |= sub(\"[^/]*\$\"; \"evil.exe\") | .architecture[\"64bit\"].hash = \"$extra_digest\""
printf 'asset-evil.exe' > "$RELEASES/Glyndor__podup/asset_evil.exe"
verify "$WORK/extra"
check "an asset the signed list does not carry is refused" "1" "$rc"
check "and the refusal says the signed list does not list it" "1" "$(said 'downloads evil.exe, which the signed SHA256SUMS of Glyndor/podup v9.9.9 does not list once')"

# --- a list whose signature does not verify ---------------------------------------
good_tree "$WORK/forged"
# Every digest the manifest declares is still in the list, so only the signature is wrong.
printf '%s  unrelated.exe\n' "$H64" >> "$RELEASES/Glyndor__podup/SHA256SUMS"
verify "$WORK/forged"
check "a SHA256SUMS whose signature does not verify is refused" "1" "$rc"
check "and the refusal is the signature's, not the digest's" "0" "$(said 'but the signed SHA256SUMS')"
rm -f "$WORK/curl.log"
CURL_STUB_LOG="$WORK/curl.log" verify "$WORK/forged"
check "and the verifier read the refused release once" "3" "$(wc -l < "$WORK/curl.log")"
check "and the verifier refused it once" "1" "$(said 'Glyndor/podup v9.9.9: the release was not admitted')"
check "and it counts as a failure for the 64bit architecture" "1" "$(said 'architecture 64bit names Glyndor/podup v9.9.9, whose release was not admitted')"
check "and it counts as a failure for the arm64 architecture" "1" "$(said 'architecture arm64 names Glyndor/podup v9.9.9, whose release was not admitted')"
check "and both digests are counted as not verified" "1" "$(said '2 of 2 published digest(s) are not the ones')"
check "and no digest was reported as verified" "0" "$(said 'verified ')"

# --- two releases of one product, the first one read again ----------------------------
# 64bit and 32bit name v9.9.9, arm64 names the older v9.9.8, whose list holds only the
# arm64 asset. Each release is read once, and the third architecture is compared with
# the list of v9.9.9 again, not with the one read last.
good_tree "$WORK/two-tags"
publish Glyndor/podup v9.9.8 podup-windows-arm64.exe
mkdir -p "$WORK/older"; cp -r "$RELEASES/Glyndor__podup/." "$WORK/older/"
publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
mkdir -p "$RELEASES/Glyndor__podup/tags"; mv "$WORK/older" "$RELEASES/Glyndor__podup/tags/v9.9.8"
edit "$WORK/two-tags" '.architecture["arm64"].url |= sub("v9.9.9"; "v9.9.8") | .architecture["32bit"] = .architecture["64bit"]'
rm -f "$WORK/curl.log"
CURL_STUB_LOG="$WORK/curl.log" verify "$WORK/two-tags"
check "an architecture that names the first release again is accepted" "0" "$rc"
check "and says it read three digests" "1" "$(said 'verified 3 published digest(s)')"
check "and each of the two releases was read once" "2" "$(reads '/SHA256SUMS')"

# --- a url outside the product's repository -----------------------------------------
good_tree "$WORK/other-repo"
edit "$WORK/other-repo" '.architecture["64bit"].url |= sub("Glyndor/podup"; "Glyndor/other")'
verify "$WORK/other-repo"
check "a url that names another repository is refused" "1" "$rc"
check "and the refusal says it is not an asset of the product's repository" "1" "$(said 'which is not an asset of Glyndor/podup')"

# --- a manifest of no product, and a bucket of none ---------------------------------
good_tree "$WORK/stranger"
cp "$WORK/stranger/bucket/podup.json" "$WORK/stranger/bucket/other.json"
verify "$WORK/stranger"
check "a manifest the PRODUCTS table has no row for is refused" "1" "$rc"
check "and the refusal names the missing row" "1" "$(said 'has no row for "other"')"

good_tree "$WORK/empty"
rm "$WORK/empty/bucket/podup.json"
verify "$WORK/empty"
check "a bucket with no manifest is not a pass" "1" "$rc"
check "and says that nothing was read" "1" "$(said 'no digest was read against a signed release')"

# --- nothing is rendered ----------------------------------------------------------------
good_tree "$WORK/readonly"
before="$(find "$WORK/readonly/bucket" -type f -exec sha256sum {} + | sort)"
verify "$WORK/readonly"
check "the verification of a good tree succeeds" "0" "$rc"
check "and writes nothing under bucket/" "$before" "$(find "$WORK/readonly/bucket" -type f -exec sha256sum {} + | sort)"
check "and renders nothing" "0" "$(said 'rendered bucket/')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
