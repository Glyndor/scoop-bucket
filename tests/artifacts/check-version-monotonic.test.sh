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

# The gate reads the repository from its root, wherever it is started. Run from
# a subfolder, the pathspec used to match nothing and every rollback passed.
R="$(repo subdir 1.2.0)"; printf '{"version":"1.1.0"}\n' > "$R/bucket/p.json"; mkdir "$R/bucket/deep"
rc=0; (cd "$R/bucket/deep" && "$HERE/scripts/artifacts/check-version-monotonic.sh" HEAD) >"$WORK/out" 2>&1 || rc=$?
check "a rollback is refused when the gate starts in a subfolder" "1" "$rc"
check "  and says which manifest went back" "1" "$(grep -c 'bucket/p.json: version 1.1.0 is below' "$WORK/out")"

R="$(repo none 1.0.0)"; git -C "$R" rm -q -r bucket
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m empty
rc=0; gate "$R" || rc=$?
check "a base with no manifest is refused, not approved" "1" "$rc"
check "  and the error says nothing was compared" "1" "$(grep -c 'nothing was compared' "$WORK/out")"

# A reviewed rollback: the approval is a line in scripts/artifacts/approved-rollbacks.txt
# on the BASE commit, naming the manifest, the committed version and the version it
# may go back to. Everything not named there stays refused.
approved_repo() { # $1=name $2=base version $3=content of the approvals file
	local r; r="$(repo "$1" "$2")"
	mkdir -p "$r/scripts/artifacts"
	printf '%s\n' "$3" > "$r/scripts/artifacts/approved-rollbacks.txt"
	git -C "$r" -c user.name=t -c user.email=t@example.invalid add -A
	git -C "$r" -c user.name=t -c user.email=t@example.invalid commit -q -m approval
	echo "$r"
}
setv() { printf '{"version":"%s"}\n' "$2" > "$1/bucket/p.json"; }
R="$(approved_repo ap1 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "an approved rollback of exactly that manifest and those versions passes" "0" "$rc"
check "  and the warning names the approval" "1" "$(grep -c 'rollback from 1.2.0 to 1.1.9 is approved' "$WORK/out")"

R="$(approved_repo ap2 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.0; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "an approval for one target does not cover a lower one" "1" "$rc"
check "  and the refusal is the downgrade rule, not the single-use one" "1" "$(grep -c 'is below the one already committed' "$WORK/out")"

R="$(approved_repo ap3 1.3.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "an approval from another committed version does not apply" "1" "$rc"
check "  and the refusal is the downgrade rule, not the single-use one" "1" "$(grep -c 'is below the one already committed' "$WORK/out")"

R="$(approved_repo ap4 1.2.0 'bucket/other.json 1.2.0 1.1.9')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "an approval for another manifest does not apply" "1" "$rc"
check "  and the refusal is the downgrade rule, not the single-use one" "1" "$(grep -c 'is below the one already committed' "$WORK/out")"

R="$(repo ap5 1.2.0)"; setv "$R" 1.1.9
mkdir -p "$R/scripts/artifacts"; echo 'bucket/p.json 1.2.0 1.1.9' > "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "an approval that arrives with the rollback itself is not read" "1" "$rc"

R="$(approved_repo ap6 1.2.0 $'# the approved one\n\nbucket/p.json 1.2.0 1.1.9\n')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "comments and blank lines in the approvals file are ignored" "0" "$rc"

R="$(approved_repo ap7 1.2.0 $'bucket/p.json 1.2.0 1.1.9\nnot a line')"; setv "$R" 1.1.9
rc=0; gate "$R" || rc=$?
check "a malformed approvals file fails closed even for a listed rollback" "1" "$rc"

R="$(approved_repo ap8 1.2.0 'bucket/p.json 1.2.0 junk')"; setv "$R" 1.1.9
rc=0; gate "$R" || rc=$?
check "an approval naming a version that is not SemVer fails closed" "1" "$rc"

# A line can be well-formed in every field but one: the right number of fields with good versions
# on a file that is not a manifest, or one field short. Either makes the whole file grant nothing.
R="$(approved_repo ap7b 1.2.0 $'bucket/p.json 1.2.0 1.1.9\nbucket/q.txt 1.0.0 0.9.0')"; setv "$R" 1.1.9
rc=0; gate "$R" || rc=$?
check "an approval for a file that is not a manifest makes the file grant nothing" "1" "$rc"
check "and the gate says the file grants nothing until it is repaired" "1" "$(grep -c 'grants nothing until it is repaired' "$WORK/out")"
R="$(approved_repo ap7c 1.2.0 $'bucket/p.json 1.2.0 1.1.9\nbucket/q.json 1.0.0')"; setv "$R" 1.1.9
rc=0; gate "$R" || rc=$?
check "an approval one field short makes the file grant nothing" "1" "$rc"
check "and the gate says the file grants nothing until it is repaired (short line)" "1" "$(grep -c 'grants nothing until it is repaired' "$WORK/out")"

R="$(approved_repo ap9 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.3.0
rc=0; gate "$R" || rc=$?
check "an approval does not stop an ordinary upgrade" "0" "$rc"

# The permission is read from the BASE commit, not from the history of the pull
# request: the approval is committed together with the rollback, on top of a base
# that does not have it, and the gate has to refuse.
R="$(repo bs1 1.2.0)"; BASE_SHA="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$R/scripts/artifacts"; echo 'bucket/p.json 1.2.0 1.1.9' > "$R/scripts/artifacts/approved-rollbacks.txt"
setv "$R" 1.1.9
git -C "$R" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m "approval and rollback together"
rc=0; gate "$R" "" "$BASE_SHA" || rc=$?
check "an approval committed in the pull request itself is not read from there" "1" "$rc"

# A used approval has to be removed, or it would allow the same rollback again.
R="$(approved_repo st1 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9
rc=0; gate "$R" || rc=$?
check "a rollback that leaves its approval line in the tree is refused" "1" "$rc"
check "  and the error says the approval has been used" "1" "$(grep -c 'has been used' "$WORK/out")"
R="$(approved_repo st2 1.2.0 'bucket/p.json 1.2.0 1.1.9')"
rc=0; gate "$R" || rc=$?
check "a pending approval whose rollback has not happened is not stale" "0" "$rc"

# Build metadata does not take part in precedence, so it does not take part in the match.
R="$(approved_repo bm1 1.2.0+a 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9+b; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "an approval matches a version whatever its build metadata" "0" "$rc"

# The summary says when a formula went back under an approval.
R="$(approved_repo sm1 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "the summary counts the approved rollback" "1" "$(grep -c '1 approved rollback(s)' "$WORK/out")"
check "  and no longer says that none goes back" "0" "$(grep -c 'none goes back' "$WORK/out")"

# A rollback may only delete approval lines, never add or alter one: the permission for
# the next rollback, or for another file, cannot ride along with this one.
R="$(approved_repo rd1 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9
printf '%s\n' 'bucket/p.json 1.2.0 1.0.0' > "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "a rollback that rewrites its own approval line is refused" "1" "$rc"
check "  and the error says the permission has to land first" "1" "$(grep -c 'cannot also add or change an approval' "$WORK/out")"

R="$(approved_repo rd2 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9
printf '%s\n' 'bucket/q.json 5.0.0 4.0.0' > "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "a rollback that installs the approval of another file is refused" "1" "$rc"

R="$(approved_repo rd3 1.2.0 'bucket/p.json 1.2.0 1.1.9')"
printf '%s\n%s\n' 'bucket/p.json 1.2.0 1.1.9' 'bucket/q.json 5.0.0 4.0.0' > "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "a pull request that only adds an approval, with no rollback, passes" "0" "$rc"

R="$(approved_repo rd4 1.2.0 $'bucket/p.json 1.2.0 not-a-version')"
printf '%s\n' 'bucket/p.json 1.2.0 1.1.9' > "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "a malformed approvals file at the base does not block the pull request that repairs it" "0" "$rc"
check "  and the warning says it grants nothing until repaired" "1" "$(grep -c 'grants nothing until it is repaired' "$WORK/out")"

R="$(approved_repo rd5 1.2.0 $'bucket/p.json 1.2.0 not-a-version')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "a malformed approvals file at the base grants no rollback" "1" "$rc"

# A line the parser would call valid on its own but SemVer would not (a leading zero in
# a numeric pre-release) stops the file like any other bad line, and grants nothing.
R="$(approved_repo lz1 1.2.0 $'bucket/p.json 1.2.0 1.1.9\nbucket/q.json 2.0.0 1.0.0-01')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" || rc=$?
check "an approval naming 1.0.0-01 is malformed, so the file grants nothing" "1" "$rc"

# Control: the approvals lookup removed, so the approved rollback is refused.
CUT2="$WORK/cut2.sh"
sed 's/if any(n == name and core(a) == core(old_version)/if False and any(n == name and core(a) == core(old_version)/' "$HERE/scripts/artifacts/check-version-monotonic.sh" > "$CUT2"
chmod +x "$CUT2"
check "the approvals control differs from the gate" "1" "$(cmp -s "$CUT2" "$HERE/scripts/artifacts/check-version-monotonic.sh" && echo 0 || echo 1)"
R="$(approved_repo apc 1.2.0 'bucket/p.json 1.2.0 1.1.9')"; setv "$R" 1.1.9; rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" "$CUT2" || rc=$?
check "without the lookup the approved rollback is refused (the pass was the lookup's)" "1" "$rc"

# Control: read the approvals from HEAD instead of the base, and the same case passes.
CUT3="$WORK/cut3.sh"
sed 's/f"{base}:{APPROVALS}"/f"HEAD:{APPROVALS}"/g' "$HERE/scripts/artifacts/check-version-monotonic.sh" > "$CUT3"
chmod +x "$CUT3"
check "the read-source control differs from the gate" "1" "$(cmp -s "$CUT3" "$HERE/scripts/artifacts/check-version-monotonic.sh" && echo 0 || echo 1)"
R="$(repo bs2 1.2.0)"; BASE_SHA="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$R/scripts/artifacts"; echo 'bucket/p.json 1.2.0 1.1.9' > "$R/scripts/artifacts/approved-rollbacks.txt"
setv "$R" 1.1.9
git -C "$R" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m "approval and rollback together"
rm "$R/scripts/artifacts/approved-rollbacks.txt"
rc=0; gate "$R" "$CUT3" "$BASE_SHA" || rc=$?
check "reading the approvals from HEAD would let the pull request approve itself" "0" "$rc"
rc=0; gate "$R" "" "$BASE_SHA" || rc=$?
check "the real gate refuses that same pull request as a downgrade" "1" "$rc"
check "  and says it is the downgrade rule" "1" "$(grep -c 'is below the one already committed' "$WORK/out")"

# Control: the same rollback, with the comparison replaced by `false`.
CUT="$WORK/cut.sh"
sed 's/if precedence(new_version, name) < old:/if False:/' "$HERE/scripts/artifacts/check-version-monotonic.sh" > "$CUT"
chmod +x "$CUT"
check "the control differs from the gate" "1" "$(cmp -s "$CUT" "$HERE/scripts/artifacts/check-version-monotonic.sh" && echo 0 || echo 1)"
R="$(repo ctl 1.2.0)"; printf '{"version":"1.1.0"}\n' > "$R/bucket/p.json"
rc=0; gate "$R" "$CUT" || rc=$?
check "without the comparison the rollback passes" "0" "$rc"

# Controls for the two guards above, each removed on its own.
python3 -I - "$HERE/scripts/artifacts/check-version-monotonic.sh" "$WORK/noroot.sh" "$WORK/noguard.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
root = 'os.chdir(git("rev-parse", "--show-toplevel").strip())'
guard = "if not names:"
assert root in s and guard in s
# The guard alone would still refuse the subfolder run, so the first control
# loses both: it shows the pathspec finding nothing is what the root fixes.
open(sys.argv[2], "w").write(s.replace(root, "pass", 1).replace(guard, "if False:", 1))
open(sys.argv[3], "w").write(s.replace(guard, "if False:", 1))
PY
chmod +x "$WORK/noroot.sh" "$WORK/noguard.sh"
R="$(repo ctlsub 1.2.0)"; printf '{"version":"1.1.0"}\n' > "$R/bucket/p.json"; mkdir "$R/bucket/deep"
rc=0; (cd "$R/bucket/deep" && "$WORK/noroot.sh" HEAD) >"$WORK/out" 2>&1 || rc=$?
check "without the root, a rollback from a subfolder passes" "0" "$rc"
R="$(repo ctlnone 1.0.0)"; git -C "$R" rm -q -r bucket
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m empty
rc=0; gate "$R" "$WORK/noguard.sh" || rc=$?
check "without the guard, a base with no manifest passes" "0" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
