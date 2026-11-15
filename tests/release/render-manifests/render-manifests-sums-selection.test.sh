#!/usr/bin/env bash
# Signed sums are a lookup table, not a whole-file grammar gate. Irrelevant
# text cannot weaken the comparison between a selected digest and its bytes.
set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

for shape in extra-field invalid-line other-duplicates; do
	new_root "$WORK/$shape"
	generator_with "$WORK/$shape/scripts/release/render-manifests.sh" "$PODUP"
	for digest in "$H64" ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff; do
		publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
		{
			printf '%s  podup-windows-x86_64.exe' "$digest"
			if [ "$shape" = extra-field ]; then printf ' basura'; fi
			printf '\n%s  podup-windows-arm64.exe\n' "$HARM"
			case "$shape" in
				invalid-line) printf 'this-is-not-a-checksum-line\n' ;;
				other-duplicates)
					printf '%s  unrelated.exe\n%s  unrelated.exe\n' "$H64" "$HARM"
					;;
			esac
		} > "$WORK/tmpsums"
		resign "$WORK/tmpsums" Glyndor/podup
		rc=0; run "$WORK/$shape/scripts/release/render-manifests.sh" "$WORK/$shape" || rc=$?
		if [ "$digest" = "$H64" ]; then
			# Intentional acceptance: hash_of selects by $2 and returns $1.
			# No selected hash is ambiguous or changed by these three shapes.
			check "$shape with the correct selected digest is accepted" "0" "$rc"
			check "$shape renders the selected digest" "$H64" \
				"$(jq -r '.architecture."64bit".hash' "$WORK/$shape/bucket/podup.json")"
			cp "$WORK/$shape/bucket/podup.json" "$WORK/before.json"
		else
			# A valid signature and tolerated text must not excuse a false
			# selected digest. Removing the byte comparison breaks each case.
			check "$shape with a false signed digest is refused" "3" "$rc"
			check "$shape refusal is the downloaded digest comparison" "1" \
				"$(grep -c 'not the .* that SHA256SUMS declares' "$WORK/out" || true)"
			check "$shape preserves the served manifest" "0" \
				"$(cmp -s "$WORK/before.json" "$WORK/$shape/bucket/podup.json"; echo $?)"
			check "$shape reports no publication" "0" "$(grep -c '^rendered ' "$WORK/out" || true)"
		fi
	done
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
