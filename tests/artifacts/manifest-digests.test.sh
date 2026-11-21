#!/usr/bin/env bash
#
# Tests for scripts/artifacts/manifest-digests.sh, the manifest that lets the
# commit job of update.yml refuse bytes the render job did not produce.
#
# The commit job is the only job holding the updater app's key, and the render
# job before it reads what a product published: a signed SHA256SUMS, a
# signature, release assets and answers from the GitHub API. What this script
# decides is whether the files about to be committed are the rendered ones, so
# every case that must be refused is planted here and has to fail with its own
# message, and a refused `place` has to leave the checkout untouched.
#
# Requires: coreutils.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
DIGESTS="$HERE/scripts/artifacts/manifest-digests.sh"
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

# A tree with two manifests, written so that bytewise order and the order a
# locale would pick can differ (an upper-case name sorts first in C and last
# in a collation that ignores case). The name is not one the roster could
# produce: the case is about the collation the script imposes, not about the
# names it is given.
tree() { # $1=dir
	rm -rf "$1"; mkdir -p "$1/bucket"
	printf '{"version":"1"}\n' > "$1/bucket/podup.json"
	printf '{"version":"1"}\n' > "$1/bucket/Zebra.json"
}

run() { # <args...>; sets rc and leaves the output in $WORK/out
	rc=0
	bash "$DIGESTS" "$@" > "$WORK/out" 2>&1 || rc=$?
}

said() { # <text>
	grep -cF -- "$1" "$WORK/out"
}

# --- list ---------------------------------------------------------------------

tree "$WORK/a"
run list "$WORK/a"
check "a tree with two manifests lists" "0" "$rc"
check "one line per file" "2" "$(wc -l < "$WORK/out" | tr -d ' ')"
check "in bytewise order" "bucket/Zebra.json bucket/podup.json" "$(awk '{print $2}' "$WORK/out" | tr '\n' ' ' | sed 's/ $//')"
check "each line is the file's SHA-256 and its path" \
	"$(cd "$WORK/a" && sha256sum bucket/podup.json)" "$(grep -F 'bucket/podup.json' "$WORK/out")"
cp "$WORK/out" "$WORK/a.sha256"
check "and sha256sum -c accepts the manifest" "0" \
	"$(cd "$WORK/a" && sha256sum --quiet -c "$WORK/a.sha256" >/dev/null 2>&1; echo $?)"

mkdir -p "$WORK/a/bucket/nested"
printf 'x\n' > "$WORK/a/bucket/nested/deep.json"
run list "$WORK/a"
check "a file at any depth is listed" "1" "$(said 'bucket/nested/deep.json')"
rm -rf "$WORK/a/bucket/nested"

run list "$WORK/missing"
check "a root with no bucket/ is refused" "1" "$rc"
check "and the message says so" "1" "$(said 'is missing or is not a directory')"

mkdir -p "$WORK/link/real"
ln -s real "$WORK/link/bucket"
run list "$WORK/link"
check "a bucket/ that is a symlink is refused" "1" "$rc"
check "and the message names it" "1" "$(said 'bucket is a symlink')"

tree "$WORK/sym"
ln -s podup.json "$WORK/sym/bucket/alias.json"
run list "$WORK/sym"
check "a symlink inside bucket/ is refused" "1" "$rc"
check "and the message names the entry" "1" "$(said 'bucket/alias.json is neither a regular file nor a directory')"

tree "$WORK/nl"
printf 'x\n' > "$WORK/nl/bucket/two
lines.json"
run list "$WORK/nl"
check "a path with a newline is refused" "1" "$rc"
check "and the message names the character set" "1" "$(said 'control character or a backslash')"

tree "$WORK/bs"
printf 'x\n' > "$WORK/bs/bucket/back\\slash.json"
run list "$WORK/bs"
check "a path with a backslash is refused" "1" "$rc"
check "and the message names the character set" "1" "$(said 'control character or a backslash')"

# A name outside ASCII is a name the renderer cannot produce and the commit
# step has to carry anyway, so the manifest has to hold it.
tree "$WORK/utf8"
printf '{"version":"1"}\n' > "$WORK/utf8/bucket/café.json"
run list "$WORK/utf8"
check "a name outside ASCII is listed" "0" "$rc"
check "and the line carries it" "1" "$(said 'bucket/café.json')"

tree "$WORK/sp"
printf 'x\n' > "$WORK/sp/bucket/a b.json"
run list "$WORK/sp"
check "a path with a space is listed" "0" "$rc"
cp "$WORK/out" "$WORK/sp.sha256"
check "and sha256sum -c reads that line back" "0" \
	"$(cd "$WORK/sp" && sha256sum --quiet -c "$WORK/sp.sha256" >/dev/null 2>&1; echo $?)"

mkdir -p "$WORK/empty/bucket/sub"
run list "$WORK/empty"
check "a bucket/ with no file is refused" "1" "$rc"
check "and the message says an empty bucket is not recorded" "1" "$(said 'refusing to record an empty bucket')"

# --- check --------------------------------------------------------------------

tree "$WORK/c"
bash "$DIGESTS" list "$WORK/c" > "$WORK/c.sha256"
run check "$WORK/c" "$WORK/c.sha256"
check "the tree that was recorded passes" "0" "$rc"
check "and says how many files matched" "1" "$(said '2 file(s) under')"

printf '# one more byte\n' >> "$WORK/c/bucket/podup.json"
run check "$WORK/c" "$WORK/c.sha256"
check "a changed byte is refused" "1" "$rc"
check "and the message says the files are not the recorded ones" "1" \
	"$(said 'are not the ones the render job recorded')"
check "and the difference names the file" "1" "$(grep -c 'bucket/podup.json' "$WORK/out" | awk '{print ($1 >= 1)}')"

tree "$WORK/c"
printf '{"version":"1"}\n' > "$WORK/c/bucket/extra.json"
run check "$WORK/c" "$WORK/c.sha256"
check "a file added after the record is refused" "1" "$rc"

tree "$WORK/c"
rm "$WORK/c/bucket/Zebra.json"
run check "$WORK/c" "$WORK/c.sha256"
check "a file missing from the tree is refused" "1" "$rc"

tree "$WORK/c"
: > "$WORK/empty.sha256"
run check "$WORK/c" "$WORK/empty.sha256"
check "an empty expected manifest is refused" "1" "$rc"
check "and the message names the manifest" "1" "$(said 'is missing or empty')"
run check "$WORK/c" "$WORK/nowhere.sha256"
check "a missing expected manifest is refused" "1" "$rc"

# --- place --------------------------------------------------------------------

tree "$WORK/from"
bash "$DIGESTS" list "$WORK/from" > "$WORK/from.sha256"
mkdir -p "$WORK/root/bucket"
printf 'stale\n' > "$WORK/root/bucket/stale.json"
run place "$WORK/from" "$WORK/root" "$WORK/from.sha256"
check "placing a recorded tree succeeds" "0" "$rc"
check "and the root now holds exactly the recorded files" "" \
	"$(diff -r "$WORK/from/bucket" "$WORK/root/bucket" 2>&1)"
check "so a manifest the render removed is gone" "no" "$([ -e "$WORK/root/bucket/stale.json" ] && echo yes || echo no)"

printf '{"version":"2"}\n' > "$WORK/from/bucket/podup.json"
printf 'mine\n' > "$WORK/root/bucket/keep.json"
before="$(cd "$WORK/root" && find bucket -type f | sort | xargs sha256sum)"
run place "$WORK/from" "$WORK/root" "$WORK/from.sha256"
check "placing a tampered tree is refused" "1" "$rc"
check "and the checkout is left as it was" "$before" \
	"$(cd "$WORK/root" && find bucket -type f | sort | xargs sha256sum)"

# --- usage ----------------------------------------------------------------------

run frobnicate
check "an unknown mode is refused" "1" "$rc"
run check "$WORK/c"
check "a check without a manifest is refused" "1" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
