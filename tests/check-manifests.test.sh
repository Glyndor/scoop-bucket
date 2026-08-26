#!/usr/bin/env bash
#
# Tests for scripts/check-manifests.sh.
#
# This script is the last thing between a rendered manifest and `scoop install`.
# update.yml commits straight to main -- the organisation forbids Actions from
# opening pull requests, so there is no review step -- and this runs before that
# commit lands. It also runs in CI. Until recently it was two copies, one in
# each workflow, with a comment on both asking whoever edited one to keep the
# other in step.
#
# Every case asserts which refusal fired. The script runs under `set -euo
# pipefail`, so almost any mistake exits non-zero and a bare non-zero assertion
# is satisfied by the failure nobody meant. Each rejection is paired with an
# acceptance of the same shape just inside the limit.
#
# Requires: jq.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/scripts/check-manifests.sh"
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

# A complete manifest, which every case below starts from and then breaks in
# exactly one way. Building each fixture from scratch invites a second defect
# that fires first and satisfies the assertion for the wrong reason.
complete() {
	cat <<'JSON'
{
  "version": "1.0.0",
  "homepage": "https://example.invalid",
  "license": "MIT",
  "architecture": {
    "64bit": {
      "url": "https://example.invalid/x.zip",
      "hash": "0000000000000000000000000000000000000000000000000000000000000000",
      "bin": ["x.exe"]
    }
  }
}
JSON
}

# $1=dir name, $2=jq filter applied to the complete manifest ('.' for unchanged)
mkbucket() {
	local d="$WORK/$1"; mkdir -p "$d"
	complete | jq "$2" > "$d/podup.json"
	echo "$d"
}

# --- a complete manifest ----------------------------------------------------
B="$(mkbucket ok '.')"
rc=0; run "$B" || rc=$?
check "a complete manifest passes" "0" "$rc"
check "and it names the file it accepted" "1" "$(said 'podup.json')"

# --- each required root field, one at a time --------------------------------
for field in version homepage license architecture; do
	B="$(mkbucket "no-$field" "del(.$field)")"
	rc=0; run "$B" || rc=$?
	check "a manifest with no $field is refused" "1" "$rc"
	check "and the error names the file (no $field)" "1" "$(said 'podup.json')"
done

# --- an empty version string is not a version -------------------------------
#
# `.version | type == "string"` alone is satisfied by "". Scoop would install a
# package with no version and every later upgrade check would compare against
# nothing.
B="$(mkbucket empty-version '.version = ""')"
rc=0; run "$B" || rc=$?
check "an empty version string is refused" "1" "$rc"

B="$(mkbucket short-version '.version = "0"')"
rc=0; run "$B" || rc=$?
check "and a one-character version is accepted" "0" "$rc"

# --- architecture must not be an empty object -------------------------------
B="$(mkbucket no-arch '.architecture = {}')"
rc=0; run "$B" || rc=$?
check "an architecture object with no entries is refused" "1" "$rc"

# --- each per-architecture field --------------------------------------------
for field in url hash bin; do
	B="$(mkbucket "no-arch-$field" "del(.architecture[\"64bit\"].$field)")"
	rc=0; run "$B" || rc=$?
	check "an architecture missing $field is refused" "1" "$rc"
done

# bin must be an array. A bare string is the mistake a hand edit makes, and
# `.value.bin` alone is truthy for it.
B="$(mkbucket bin-string '.architecture["64bit"].bin = "x.exe"')"
rc=0; run "$B" || rc=$?
check "a bin that is a string rather than an array is refused" "1" "$rc"

# --- one bad manifest among several -----------------------------------------
#
# The loop must not stop reporting at the first good one.
B="$(mkbucket mixed '.')"
complete | jq 'del(.license)' > "$B/broken.json"
rc=0; run "$B" || rc=$?
check "one bad manifest among several fails the run" "1" "$rc"
check "and the error names the bad one" "1" "$(said 'broken.json')"

# --- invalid JSON -----------------------------------------------------------
B="$WORK/badjson"; mkdir -p "$B"
printf '{ this is not json' > "$B/podup.json"
rc=0; run "$B" || rc=$?
check "a file that is not JSON is refused" "1" "$rc"

# --- an empty bucket --------------------------------------------------------
#
# This is the case the script exists for as much as any field check. A loop
# over no manifests succeeds, so "every manifest is valid" is true of a bucket
# that serves nobody -- and update.yml commits the result straight to main.
B="$WORK/empty"; mkdir -p "$B"
rc=0; run "$B" || rc=$?
check "an empty bucket is refused rather than passing vacuously" "1" "$rc"
check "and says no manifests were found" "1" "$(said 'no manifests found')"

# --- this repository --------------------------------------------------------
rc=0; run "$HERE/bucket" || rc=$?
check "the manifests in this repository are valid" "0" "$rc"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
