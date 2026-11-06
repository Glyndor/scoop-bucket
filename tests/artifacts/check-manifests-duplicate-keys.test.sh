#!/usr/bin/env bash
#
# A JSON object with a repeated key is read differently by different readers:
# jq keeps the last value and says nothing, PowerShell's ConvertFrom-Json
# refuses the file. So check-manifests.sh would validate one value while a
# consumer installs or rejects another. The gate has to refuse a repeated key
# at any depth, name the key and say where it sits.
#
# Requires: jq, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$HERE/scripts/artifacts/check-manifests.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

run() { "$CHECK" "$1" >"$WORK/out" 2>&1; }
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

# A bucket holding one hand-written podup.json, so the repeated key is really
# in the text (jq would collapse it).
bucket() { # $1=name, stdin=the manifest text
	local d="$WORK/$1"; mkdir -p "$d"
	cat > "$d/podup.json"
	echo "$d"
}

GOOD_TAIL='"description": "test", "homepage": "https://github.com/Glyndor/podup", "license": "MIT"'
URL='https://github.com/Glyndor/podup/releases/download/v1.0.0/podup-windows-x86_64.exe'
HASH=0000000000000000000000000000000000000000000000000000000000000000
ARCH="\"architecture\": {\"64bit\": {\"url\": \"$URL\", \"hash\": \"$HASH\", \"bin\": [[\"podup-windows-x86_64.exe\", \"podup\"]]}}"

B="$(printf '{"version": "1.0.0", %s, %s}\n' "$GOOD_TAIL" "$ARCH" | bucket ok)"
rc=0; run "$B" || rc=$?
check "control: a manifest with no repeated key passes" "0" "$rc"

B="$(printf '{"version": "1.0.0", "version": "9.9.9", %s, %s}\n' "$GOOD_TAIL" "$ARCH" | bucket top)"
rc=0; run "$B" || rc=$?
check "a repeated top-level key is refused" "1" "$rc"
check "and the message names the key" "1" "$(said 'duplicate key "version"')"
check "and it says the key is at the top level" "1" "$(said 'at the top level')"
check "and it names the file" "1" "$(said 'podup.json')"

B="$(printf '{"version": "1.0.0", %s, "architecture": {"64bit": {"url": "%s", "url": "https://github.com/Glyndor/podup/other.exe", "hash": "%s", "bin": [["podup-windows-x86_64.exe", "podup"]]}}}\n' "$GOOD_TAIL" "$URL" "$HASH" | bucket nested)"
rc=0; run "$B" || rc=$?
check "a repeated key inside an architecture is refused" "1" "$rc"
check "and the message names the key" "1" "$(said 'duplicate key "url"')"
check "and it says where it sits" "1" "$(said 'under "architecture" and "64bit"')"

B="$(printf '{"version": "1.0.0", %s, "architecture": {"64bit": {"url": "%s", "hash": "%s", "bin": [{"a": 1, "a": 2}]}}}\n' "$GOOD_TAIL" "$URL" "$HASH" | bucket inlist)"
rc=0; run "$B" || rc=$?
check "a repeated key inside an object in a list is refused" "1" "$rc"
check "and the message names the key" "1" "$(said 'duplicate key "a"')"

B="$(printf '{"version": "1.0.0", "version": "1.0.0", %s, %s}\n' "$GOOD_TAIL" "$ARCH" | bucket same)"
rc=0; run "$B" || rc=$?
check "a repeated key with the same value is refused too" "1" "$rc"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
