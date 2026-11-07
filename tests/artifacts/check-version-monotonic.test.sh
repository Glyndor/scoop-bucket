#!/usr/bin/env bash
#
# Tests for scripts/artifacts/check-version-monotonic.sh: a pull request cannot
# lower the version of a manifest already committed on the base branch.
#
# Each case builds a small repository whose base commit holds bucket/p.json at
# one version, changes the working tree to another and runs the gate. The
# orderings are the SemVer ones the renderer uses (pre-release below stable,
# numeric identifiers below text, build metadata ignored). The last case runs
# the same rollback against a copy of the gate whose comparison is replaced by
# `false`, and it must pass there, so the refusal is shown to come from the
# comparison and not from some other rule.
#
# Requires: git, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
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

repo() { # $1=name $2=base version -> prints the repo; the base commit is HEAD
	local r="$WORK/$1"
	mkdir -p "$r/bucket"
	printf '{"version":"%s"}\n' "$2" > "$r/bucket/p.json"
	git -C "$r" init -q
	git -C "$r" -c user.name=t -c user.email=t@example.invalid add -A
	git -C "$r" -c user.name=t -c user.email=t@example.invalid commit -q -m base
	echo "$r"
}
gate() { # $1=repo [$2=gate script] [$3=base]
	(cd "$1" && "${2:-$HERE/scripts/artifacts/check-version-monotonic.sh}" "${3:-HEAD}") >"$WORK/out" 2>&1
}

n=0
while IFS=" " read -r base head expect; do
	n=$((n + 1)); R="$(repo "c$n" "$base")"
	printf '{"version":"%s"}\n' "$head" > "$R/bucket/p.json"
	rc=0; gate "$R" || rc=$?
	check "$base -> $head ($expect)" "$([ "$expect" = ok ] && echo 0 || echo 1)" "$rc"
done <<'CASES'
1.2.0 1.2.0 ok
1.2.0 1.2.1 ok
1.2.0 1.3.0 ok
1.2.0 2.0.0 ok
1.2.0 1.1.9 refused
1.2.0 0.9.9 refused
1.10.0 1.9.0 refused
1.2.0 1.2.0-rc1 refused
1.2.0-rc1 1.2.0 ok
1.2.0-rc2 1.2.0-rc1 refused
1.2.0-rc1 1.2.0-rc2 ok
1.2.0-1 1.2.0-alpha ok
1.2.0-alpha 1.2.0-1 refused
1.2.0+a 1.2.0+b ok
1.2.0 1.2.0+build5 ok
1.2.0 not-a-version refused
1.2.0 01.2.0 refused
1.2.0-01 1.2.0 refused
CASES

R="$(repo new 1.0.0)"; printf '{"version":"0.0.1"}\n' > "$R/bucket/q.json"
rc=0; gate "$R" || rc=$?
check "a product new in the tree is not compared" "0" "$rc"

R="$(repo gone 1.0.0)"; rm "$R/bucket/p.json"
rc=0; gate "$R" || rc=$?
check "a product removed from the tree is not compared" "0" "$rc"

R="$(repo nover 1.0.0)"; printf '{"name":"p"}\n' > "$R/bucket/p.json"
rc=0; gate "$R" || rc=$?
check "a manifest with no version is refused" "1" "$rc"

R="$(repo notjson 1.0.0)"; printf 'oops' > "$R/bucket/p.json"
rc=0; gate "$R" || rc=$?
check "a manifest that is not JSON is refused" "1" "$rc"

R="$(repo badbase 1.0.0)"; printf '{"version":"x"}\n' > "$R/bucket/p.json"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -am bad
printf '{"version":"1.0.0"}\n' > "$R/bucket/p.json"
rc=0; gate "$R" "" HEAD || rc=$?
check "a base manifest with no valid version is refused" "1" "$rc"

R="$(repo nobase 1.0.0)"
rc=0; gate "$R" "" deadbeef || rc=$?
check "an unknown base commit is refused" "1" "$rc"

R="$(repo noarg 1.0.0)"
rc=0; (cd "$R" && "$HERE/scripts/artifacts/check-version-monotonic.sh") >"$WORK/out" 2>&1 || rc=$?
check "no base argument is refused" "1" "$rc"

R="$(repo msg 1.2.0)"; printf '{"version":"1.1.0"}\n' > "$R/bucket/p.json"
rc=0; gate "$R" || rc=$?
check "the error names the file and both sides" "1" "$(grep -c 'bucket/p.json: version 1.1.0 is below' "$WORK/out")"

# Control: the same rollback, with the comparison replaced by `false`.
CUT="$WORK/cut.sh"
sed 's/if precedence(new_version, name) < old:/if False:/' "$HERE/scripts/artifacts/check-version-monotonic.sh" > "$CUT"
chmod +x "$CUT"
check "the control differs from the gate" "1" "$(cmp -s "$CUT" "$HERE/scripts/artifacts/check-version-monotonic.sh" && echo 0 || echo 1)"
rc=0; gate "$R" "$CUT" || rc=$?
check "without the comparison the rollback passes" "0" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
