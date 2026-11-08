#!/usr/bin/env bash
#
# check-manifests.sh refuses anything in bucket/ that is not a regular file or a
# folder. A symlink named podup.json is matched by the manifest glob like any
# other, so the gate used to certify the link's target while the bucket served a
# path that can be repointed. Each case plants one entry and asserts the exact
# message, then the same cases run against a copy of the gate with the
# refusal removed and must flip to accepted, so the refusal is shown to come
# from that check and not from another rule.
#
# Requires: jq.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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

# A tree to run a gate from: the real gate and the real renderer (whose
# PRODUCTS table is the roster), with the committed podup.json as the manifest.
mktree() { # $1=name -> prints the tree
	local t="$WORK/$1"
	mkdir -p "$t/scripts/artifacts" "$t/scripts/release" "$t/bucket"
	cp "$HERE/scripts/artifacts/check-manifests.sh" "$t/scripts/artifacts/"
	cp "$HERE/scripts/release/render-manifests.sh" "$t/scripts/release/"
	cp "$HERE/bucket/podup.json" "$t/bucket/podup.json"
	echo "$t"
}

gate() { # $1=tree -> rc, output in $WORK/out
	"$1/scripts/artifacts/check-manifests.sh" "$1/bucket" >"$WORK/out" 2>&1
}
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

T="$(mktree good)"
rc=0; gate "$T" || rc=$?
check "control: the committed manifest alone is accepted" "0" "$rc"

# A manifest that is a symlink to a valid manifest: the glob reads it as one.
T="$(mktree link)"
mv "$T/bucket/podup.json" "$WORK/real.json"
ln -s "$WORK/real.json" "$T/bucket/podup.json"
rc=0; gate "$T" || rc=$?
check "a symlinked manifest is refused" "1" "$rc"
check "and the refusal names the entry" "1" "$(said '  podup.json')"
check "and says it is not a regular file" "1" "$(said 'holds an entry that is not a regular file')"

# A second, dangling link beside a good manifest.
T="$(mktree dangling)"
ln -s "$WORK/nowhere" "$T/bucket/other.json"
rc=0; gate "$T" || rc=$?
check "a dangling symlink beside a good manifest is refused" "1" "$rc"
check "and the refusal names the entry " "1" "$(said '  other.json')"

# A folder is not an entry this rule refuses (the subfolder rule is separate).
T="$(mktree folder)"
mkdir "$T/bucket/sub"
rc=0; gate "$T" || rc=$?
check "an empty folder is not refused by this rule" "0" "$(said 'is not a regular file')"

# The same planted entries must flip when the refusal is removed.
for c in link dangling; do
	T="$WORK/$c"
	python3 - "$T/scripts/artifacts/check-manifests.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if [ -n "$links" ]; then'
assert old in s
open(p, "w").write(s.replace(old, 'if false; then'))
PY
	rc=0; gate "$T" || rc=$?
	check "sabotaged gate: the $c case is no longer refused for that reason" "0" "$(said 'is not a regular file')"
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
