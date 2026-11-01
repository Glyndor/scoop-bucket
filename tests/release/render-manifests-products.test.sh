#!/usr/bin/env bash
# Exercise repository-controlled PRODUCTS data without evaluating it as shell.
# Known naming gaps are observations, not an approved naming policy. Keep the
# traversal inside the disposable fixture root; never execute a rendered file.
set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

# generator_with uses awk replacements, which interpret backslash escapes.
# Literal shell quoting here preserves hostile data before the renderer reads
# it, including quotes, backslashes and newlines. No fixture value is evaluated.
literal_generator() { # $1=destination $2=manifest name $3=description
	python3 - "$GENERATOR" "$1" "$2" "$3" <<'PY'
import pathlib, shlex, sys
source, dest, name, description = sys.argv[1:]
text = pathlib.Path(source).read_text()
start = text.index("PRODUCTS=(\n")
end = text.index("\n)", start) + 2
row = f"Glyndor/podup|{name}|{description}|podup-windows-x86_64.exe|-"
text = text[:start] + "PRODUCTS=(\n\t" + shlex.quote(row) + "\n)" + text[end:]
pathlib.Path(dest).write_text(text)
PY
	chmod +x "$1"
}

publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe
names=("../outside" "a/b" "-foo" "with space" 'quo"te' 'back\slash' $'line\nbreak' "café" "pod-up")
labels=(traversal nested leading-dash space quote backslash newline unicode legal-hyphen)
for i in "${!names[@]}"; do
	name="${names[i]}"
	label="${labels[i]}"
	root_case="$WORK/name-$label"
	new_root "$root_case"
	# Ensure a nested name reaches the write, rather than failing incidentally
	# because its parent does not exist. Everything stays inside this fixture.
	mkdir -p "$root_case/bucket/a"
	literal_generator "$root_case/scripts/release/render-manifests.sh" "$name" "literal description"
	rc=0; run "$root_case/scripts/release/render-manifests.sh" "$root_case" || rc=$?
	if [ "$label" = newline ]; then
		check "newline in a name is refused by the line-oriented roster" "3" "$rc"
		check "newline refusal names the missing description field" "1" \
			"$(grep -c 'has no desc' "$WORK/out" || true)"
		check "newline refusal writes no JSON" "0" "$(find "$root_case" -name '*.json' | wc -l)"
		continue
	fi
	if [ "$label" != legal-hyphen ]; then
		check "$label name is refused" "3" "$rc"
		check "$label refusal names the entry as an invalid manifest name" "1" \
			"$(grep -c 'invalid manifest name' "$WORK/out" || true)"
		check "$label writes no JSON anywhere in the fixture root" "0" \
			"$(find "$root_case" -name '*.json' | wc -l)"
		continue
	fi
	check "legal hyphenated name renders" "0" "$rc"
	manifest_path="$root_case/bucket/$name.json"
	check "legal name output parses as JSON" "0" "$(jq -e . "$manifest_path" >/dev/null 2>&1; echo $?)"
	check "legal name survives as the shim alias" "$name" \
		"$(jq -r '.architecture."64bit".bin[0][1]' "$manifest_path")"
done

# Quotes, backslashes and shell-looking text are legitimate description data.
# jq must preserve them, and none of the text may run as a command.
# Shell-looking text must remain literal data in this fixture.
# shellcheck disable=SC2016
for description in 'a "quoted" description' 'a back\slash' '$(touch PRODUCTS_EXECUTED); literal'; do
	new_root "$WORK/metadata"
	literal_generator "$WORK/metadata/scripts/release/render-manifests.sh" "pod-up" "$description"
	rc=0; run "$WORK/metadata/scripts/release/render-manifests.sh" "$WORK/metadata" || rc=$?
	check "literal metadata renders" "0" "$rc"
	check "literal metadata is preserved in parseable JSON" "$description" \
		"$(jq -er .description "$WORK/metadata/bucket/pod-up.json")"
	check "metadata does not execute shell-looking text" "0" \
		"$(find "$WORK/metadata" -name PRODUCTS_EXECUTED | wc -l)"
	check "license remains the fixed MIT value (no license column in PRODUCTS)" "MIT" \
		"$(jq -r .license "$WORK/metadata/bucket/pod-up.json")"
done

new_root "$WORK/metadata-newline"
literal_generator "$WORK/metadata-newline/scripts/release/render-manifests.sh" "pod-up" $'first\nsecond'
rc=0; run "$WORK/metadata-newline/scripts/release/render-manifests.sh" "$WORK/metadata-newline" || rc=$?
check "newline metadata cannot cross the roster record boundary" "3" "$rc"
check "newline metadata refusal names the missing asset field" "1" \
	"$(grep -c 'has no a64' "$WORK/out" || true)"
check "newline metadata writes no JSON" "0" "$(find "$WORK/metadata-newline" -name '*.json' | wc -l)"

# The repository and the asset names reach the download url too.
raw_generator() { # $1=destination $2=full roster row
	python3 - "$GENERATOR" "$1" "$2" <<'PY'
import pathlib, shlex, sys
source, dest, row = sys.argv[1:]
text = pathlib.Path(source).read_text()
start = text.index("PRODUCTS=(\n")
end = text.index("\n)", start) + 2
pathlib.Path(dest).write_text(text[:start] + "PRODUCTS=(\n\t" + shlex.quote(row) + "\n)" + text[end:])
PY
	chmod +x "$1"
}
for bad in 'a"b' 'a\b' 'a b' 'a/b' '..' '-leading' '../x'; do
	for slot in 3 4; do
		root_case="$WORK/asset-$slot-${bad//[^A-Za-z0-9]/_}"
		new_root "$root_case"
		row="Glyndor/podup|podup|desc|podup-windows-x86_64.exe|podup-windows-arm64.exe"
		row="$(python3 -c 'import sys; f=sys.argv[1].split("|"); f[int(sys.argv[2])]=sys.argv[3]; print("|".join(f))' "$row" "$slot" "$bad")"
		raw_generator "$root_case/scripts/release/render-manifests.sh" "$row"
		rc=0; run "$root_case/scripts/release/render-manifests.sh" "$root_case" || rc=$?
		check "asset name [$bad] in slot $slot is refused" "3" "$rc"
		check "and it is named as an invalid asset name ($bad, slot $slot)" "1" "$(grep -c 'invalid asset name' "$WORK/out" || true)"
		check "and no JSON is written ($bad, slot $slot)" "0" "$(find "$root_case" -name '*.json' | wc -l)"
	done
done
for bad in 'Glyndor' 'Glyndor/' '/podup' 'Glyndor/pod"up' 'Glyndor/a/b' 'Gl yndor/podup'; do
	root_case="$WORK/repo-${bad//[^A-Za-z0-9]/_}"
	new_root "$root_case"
	raw_generator "$root_case/scripts/release/render-manifests.sh" "$bad|podup|desc|podup-windows-x86_64.exe|-"
	rc=0; run "$root_case/scripts/release/render-manifests.sh" "$root_case" || rc=$?
	check "repository [$bad] is refused" "3" "$rc"
	check "and it is named as an invalid repository ($bad)" "1" "$(grep -c 'invalid repository' "$WORK/out" || true)"
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
