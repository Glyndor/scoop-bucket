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
# Every fixture breaks exactly one rule. The script refuses with a specific
# message naming the file, the field and the shape the renderer would have
# produced; the test then asserts that exact substring fired. A bare rc=1
# check would also pass on a refusal for the wrong reason, which is the
# difference between a test and a measurement.
#
# The committed bucket/podup.json is the positive control at the end of this
# file: a rendered manifest in its committed shape must still be accepted.
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

# A complete manifest that satisfies every rule. Every fixture below starts
# here and breaks one rule, so a refusal in the output must be for the rule
# the fixture breaks and no other.
#
# The url below starts with the https://github.com/Glyndor/ prefix the gate
# requires. A previous version used https://example.invalid/x.zip as a
# placeholder; once the url prefix became part of the contract, that
# placeholder would have failed the new rule and made the "a complete
# manifest passes" assertion read as a pass of the url rule.
complete() {
	cat <<'JSON'
{
  "version": "1.0.0",
  "description": "test",
  "homepage": "https://github.com/Glyndor/podup",
  "license": "MIT",
  "architecture": {
    "64bit": {
      "url": "https://github.com/Glyndor/podup/releases/download/v1.0.0/podup-windows-x86_64.exe",
      "hash": "0000000000000000000000000000000000000000000000000000000000000000",
      "bin": [["podup-windows-x86_64.exe", "podup"]]
    }
  }
}
JSON
}

mkbucket() { # $1=dir name, $2=jq filter against the complete manifest
	local d="$WORK/$1"; mkdir -p "$d"
	complete | jq "$2" > "$d/podup.json"
	echo "$d"
}

# --- a complete manifest passes ---------------------------------------------
B="$(mkbucket ok '.')"
rc=0; run "$B" || rc=$?
check "a complete manifest passes" "0" "$rc"
check "and it names the file it accepted" "1" "$(said 'podup.json')"

# --- top-level allowlist ----------------------------------------------------
#
# The renderer never emits pre_install, so the field's presence is a hand edit
# or a hijacked render. Scoop would run whatever pre_install contains on the
# user's machine.
B="$(mkbucket top-extra '. + {pre_install: ["x"]}')"
rc=0; run "$B" || rc=$?
check "a top-level field the renderer does not emit is refused" "1" "$rc"
check "and the error names the unexpected key" "1" "$(said 'pre_install')"
check "and names the file it lives in" "1" "$(said 'podup.json')"

# --- architecture key allowlist --------------------------------------------
#
# Scoop recognises 64bit, 32bit and arm64. Anything else -- 68bit, x64, x86_64
# -- is a hand edit that names no architecture Scoop can install.
B="$(mkbucket bad-arch '.architecture += {"68bit": .architecture["64bit"]}')"
rc=0; run "$B" || rc=$?
check "an architecture key outside 64bit/32bit/arm64 is refused" "1" "$rc"
check "and the error names the bad architecture" "1" "$(said '68bit')"
check "and names the expected set" "1" "$(said '64bit, 32bit, arm64')"

# --- per-architecture allowlist --------------------------------------------
#
# pre_install here is the same attack as at the top level, only closer to
# where Scoop reads it.
B="$(mkbucket arch-extra '.architecture["64bit"].pre_install = "x"')"
rc=0; run "$B" || rc=$?
check "a per-architecture field the renderer does not emit is refused" "1" "$rc"
check "and the error names the unexpected key" "1" "$(said 'pre_install')"
check "and names the architecture it lives in" "1" "$(said '"64bit"')"

# --- url must come from the org release ------------------------------------
B="$(mkbucket bad-url '.architecture["64bit"].url = "http://evil.example/payload.exe"')"
rc=0; run "$B" || rc=$?
check "a url not under https://github.com/Glyndor/ is refused" "1" "$rc"
check "and the error names the expected url prefix" "1" "$(said 'must start with https://github.com/Glyndor/')"

# --- hash must match the digest regex --------------------------------------
B="$(mkbucket bad-hash '.architecture["64bit"].hash = "notahash"')"
rc=0; run "$B" || rc=$?
check "a hash that is not 64 lowercase hex chars is refused" "1" "$rc"
check "and the error names the expected hash shape" "1" "$(said 'must match ^[0-9a-f]{64}$')"

# --- bin must be a non-empty array -----------------------------------------
#
# The previous rule was "bin must be an array". The renderer always writes
# a non-empty array, so the rule tightens to match: an empty array would
# leave Scoop with no command to expose.
B="$(mkbucket empty-bin '.architecture["64bit"].bin = []')"
rc=0; run "$B" || rc=$?
check "an empty bin array is refused" "1" "$rc"
check "and the error names the expected bin shape" "1" "$(said 'must be a non-empty array')"

# bin must be an array; a hand edit could put a string where the renderer
# writes an array of arrays.
B="$(mkbucket bin-string '.architecture["64bit"].bin = "x.exe"')"
rc=0; run "$B" || rc=$?
check "a bin that is a string is refused" "1" "$rc"
check "and the error names the expected bin shape" "1" "$(said 'must be a non-empty array')"

# --- top-level required fields are still required --------------------------
#
# The renderer always emits these; a hand edit that drops one would have Scoop
# install something it cannot describe.
for field in version homepage license architecture; do
	B="$(mkbucket "no-$field" "del(.$field)")"
	rc=0; run "$B" || rc=$?
	check "a manifest missing $field is refused" "1" "$rc"
	case "$field" in
		architecture) needle='missing required top-level field "architecture"' ;;
		*)            needle="missing required top-level field \"$field\"" ;;
	esac
	check "and the error names the missing field ($field)" "1" "$(said "$needle")"
done

# --- an empty version string is not a version ------------------------------
#
# `.version | type == "string"` alone is satisfied by "". Scoop would install a
# package with no version and every later upgrade check would compare against
# nothing.
B="$(mkbucket empty-version '.version = ""')"
rc=0; run "$B" || rc=$?
check "an empty version string is refused" "1" "$rc"
check "and the error names the version shape" "1" "$(said 'version" must be a non-empty string')"

B="$(mkbucket short-version '.version = "0"')"
rc=0; run "$B" || rc=$?
check "and a one-character version is accepted" "0" "$rc"

# --- architecture must not be an empty object ------------------------------
B="$(mkbucket no-arch '.architecture = {}')"
rc=0; run "$B" || rc=$?
check "an empty architecture object is refused" "1" "$rc"
check "and the error names the architecture shape" "1" "$(said 'architecture" must be a non-empty object')"

# --- each per-architecture field is still required -------------------------
for field in url hash bin; do
	B="$(mkbucket "no-arch-$field" "del(.architecture[\"64bit\"].$field)")"
	rc=0; run "$B" || rc=$?
	check "an architecture missing $field is refused" "1" "$rc"
	check "and the error names the missing per-arch field ($field)" "1" "$(said "missing required field \"$field\"")"
done

# --- one bad manifest among several ----------------------------------------
#
# The loop must not stop reporting at the first good one.
B="$(mkbucket mixed '.')"
complete | jq 'del(.license)' > "$B/broken.json"
rc=0; run "$B" || rc=$?
check "one bad manifest among several fails the run" "1" "$rc"
check "and the error names the bad file" "1" "$(said 'broken.json')"

# --- invalid JSON ----------------------------------------------------------
B="$WORK/badjson"; mkdir -p "$B"
printf '{ this is not json' > "$B/podup.json"
rc=0; run "$B" || rc=$?
check "a file that is not JSON is refused" "1" "$rc"
check "and the error names the bad file" "1" "$(said 'podup.json')"

# --- an empty bucket --------------------------------------------------------
#
# This is the case the script exists for as much as any field check. A loop
# over no manifests succeeds, so "every manifest is valid" is true of a bucket
# that serves nobody -- and update.yml commits the result straight to main.
B="$WORK/empty"; mkdir -p "$B"
rc=0; run "$B" || rc=$?
check "an empty bucket is refused rather than passing vacuously" "1" "$rc"
check "and says no manifests were found" "1" "$(said 'no manifests found')"

# --- an architecture whose value is not an object ---------------------------
#
# jq reads keys off the value, and asking a string for its keys aborts the
# whole invocation. Before this case the run died with `has no keys` and exit
# 5, which fails closed but names no file and no field, so the person reading
# CI learns nothing about which manifest to look at.
B="$(mkbucket archnotobject '.architecture."64bit" = "nope"')"
rc=0; run "$B" || rc=$?
check "an architecture whose value is not an object is refused" "1" "$rc"
check "and the error says what it should have been" "1" \
	"$(said 'must be an object, not string')"
check "and names the architecture" "1" "$(said '"64bit"')"

# --- the url prefix is a literal, not a pattern -----------------------------
#
# The prefix was compared with a regex, and an unescaped `.` matches any
# character, so a host one character away from github.com was accepted. The
# comparison is a literal prefix now, and this is the case that says so.
B="$(mkbucket urlwildcard '.architecture."64bit".url = "https://githubXcom/Glyndor/podup/releases/download/v1.0.0/podup-windows-x86_64.exe"')"
rc=0; run "$B" || rc=$?
check "a host that only matches the prefix as a pattern is refused" "1" "$rc"
check "and the error names the expected url prefix" "1" \
	"$(said 'must start with https://github.com/Glyndor/')"

# --- this repository --------------------------------------------------------
rc=0; run "$HERE/bucket" || rc=$?
check "the manifests in this repository are valid" "0" "$rc"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
