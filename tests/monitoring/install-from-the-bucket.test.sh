#!/usr/bin/env bash
#
# scripts/monitoring/install-from-the-bucket.sh installs an app from the published bucket with Scoop and updates it from
# the version before. It runs where nobody watches, after the updater pushes, so each way it could say "it installs"
# wrongly has to be shown here to say no: a manifest that installs another version than it declares, a program that
# prints another version or does not start, an update that changes nothing or leaves the old program in place, and a
# history with nothing to update from, which is not a pass.
#
# The script is run as it ships, with `scoop` replaced by a stub that keeps what is installed in a folder and reads the
# version of the manifest the bucket clone holds at that moment, over a git repository planted for each case. What only
# a real Scoop can answer (that `scoop install` really downloads and shims, that `scoop update` really replaces, the
# format of `scoop export`) is not covered here: it is what the first run of the workflow on GitHub shows.
# Requires: bash, git, jq, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/install-from-the-bucket.sh"
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

for tool in git jq python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "NOTE  $tool is missing, so nothing below could run. Not a pass."; exit 1; }
done

R="$WORK/checkout"; T="$WORK/tapclone"; S="$WORK/state"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/scoop" <<'STUB'
#!/usr/bin/env bash
tapversion() { jq -r .version "$TAPDIR/bucket/probe.json"; }
program() { # <what it prints>
	mkdir -p "$STATE/bin"
	if [ -n "${STUB_NOSTART:-}" ]; then printf '#!/bin/sh\nexit 126\n' > "$STATE/bin/probe"
	else printf '#!/bin/sh\necho "probe %s"\n' "$1" > "$STATE/bin/probe"; fi
	chmod +x "$STATE/bin/probe"
}
calls() { local n; n=$(( $(cat "$STATE/n.$1" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/n.$1"; echo "$n"; }
case "$1" in
	bucket) [ -z "${STUB_TAP_FAIL:-}" ] || exit 1 ;;
	export) if [ -f "$STATE/installed" ]; then printf '{"apps":[{"Name":"probe","Version":"%s"}]}\n' "$(cat "$STATE/installed")"; else echo '{"apps":[]}'; fi ;;
	install)
		n="$(calls install)"
		[ -z "${STUB_INSTALL_FAIL:-}" ] || exit 1
		[ "${STUB_INSTALL_FAIL_NTH:-}" != "$n" ] || exit 1
		v="${STUB_INSTALL_AS:-$(tapversion)}"; [ "${STUB_INSTALL_AS_NTH:-}" != "$n" ] || v=9.9.9
		echo "$v" > "$STATE/installed"; program "${STUB_PRINTS:-$v}"
		[ "${STUB_LOCK_ON_INSTALL_NTH:-}" != "$n" ] || chmod 555 "$TAPDIR/bucket" ;;
	uninstall)
		[ -z "${STUB_UNINSTALL_FAIL:-}" ] || exit 1
		rm -f "$STATE/installed"; [ -z "${STUB_LOCK_ON_UNINSTALL:-}" ] || chmod 555 "$TAPDIR/bucket" ;;
	update)
		[ -z "${STUB_UPGRADE_FAIL:-}" ] || exit 1
		[ -z "${STUB_UPGRADE_NOOP:-}" ] || exit 0
		v="$(tapversion)"; echo "$v" > "$STATE/installed"
		[ -n "${STUB_UPGRADE_OLD_PROGRAM:-}" ] || program "$v" ;;
esac
STUB
chmod +x "$WORK/bin/scoop"

manifest() { # <version>
	printf '{"version": "%s", "architecture": {"64bit": {"url": "https://github.com/Glyndor/probe/releases/download/v%s/probe.exe", "hash": "%064d", "bin": "probe.exe"}}}\n' "$1" "$1" "$RANDOM"
}
plant() { # <version>... : a checkout with one commit of the manifest for each version, and a clone of it as the bucket
	chmod -R u+w "$T" 2>/dev/null; rm -rf "$R" "$T" "$S"; mkdir -p "$R/bucket" "$S"
	git -C "$R" init -q -b main; git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	local tag
	for tag in "$@"; do manifest "$tag" > "$R/bucket/probe.json"; git -C "$R" add -A; git -C "$R" commit -q -m "manifest $tag"; done
	git clone -q "$R" "$T"
}
run() {
	chmod -R u+w "$T" 2>/dev/null
	( cd "$R" && TAPDIR="$T" STATE="$S" BUCKET=probe BUCKET_URL=https://example.invalid/probe BUCKET_DIR="${BUCKET_DIR_FOR_RUN:-$T}" PATH="$WORK/bin:$S/bin:/usr/bin:/bin" bash "$SCRIPT" probe >"$WORK/out" 2>&1 ); echo $?
}
said() { grep -c -- "$1" "$WORK/out"; }
# fails <description> <message> <variable=value>... : plant the history, run with the variables set, expect the failure and its message
fails() {
	local description="$1" message="$2" kv status; shift 2
	plant 5.0.0 6.0.0
	for kv in "$@"; do export "${kv?}"; done
	status="$(run)"
	for kv in "$@"; do unset "${kv%%=*}"; done
	check "$description" "1" "$status"
	check "and says so" "1" "$(said "$message")"
}

plant 5.0.0 6.0.0
check "a manifest that installs, starts and updates from the version before passes" "0" "$(run)"
check "and says it installs, from which manifest it went back, and the update" "1" "$(said 'probe 5.0.0 installed from the manifest of')"
check "and what it went from and to" "1" "$(said 'went from 5.0.0 to 6.0.0 with scoop update')"
check "and the program the user is left with is the new one" "probe 6.0.0" "$(PATH="$S/bin:$PATH" probe)"

plant 6.0.0
check "a bucket with no earlier version of the manifest is exit 3" "3" "$(run)"
check "and says it was not verified" "1" "$(said 'NOT VERIFIED')"
plant 6.0.0 6.0.0
check "the same version rendered twice is no earlier version either" "3" "$(run)"

fails "a bucket that cannot be added fails" 'cannot be added' STUB_TAP_FAIL=1
plant 5.0.0 6.0.0; BUCKET_DIR_FOR_RUN="$WORK/no-such-folder"; export BUCKET_DIR_FOR_RUN; check "a clone that is not a folder fails" "1" "$(run)"; unset BUCKET_DIR_FOR_RUN
check "and says so" "1" "$(said 'is not a folder')"
plant 5.0.0 6.0.0; mkdir -p "$WORK/plain"; BUCKET_DIR_FOR_RUN="$WORK/plain"; export BUCKET_DIR_FOR_RUN; check "a clone that is not a repository fails" "1" "$(run)"; unset BUCKET_DIR_FOR_RUN
check "and says it has no HEAD" "1" "$(said 'has no HEAD')"
plant 5.0.0 6.0.0; printf '{"description": "x"}\n' > "$T/bucket/probe.json"; check "a manifest with no version fails" "1" "$(run)"
check "and says so" "1" "$(said 'declares no version')"

fails "an install that fails fails" 'scoop install probe/probe failed' STUB_INSTALL_FAIL=1
fails "an install that lands on another version than the manifest declares fails" 'installed probe 6.0.1, not the 6.0.0' STUB_INSTALL_AS=6.0.1
fails "a program that prints another version fails" 'prints "probe 0.0.1"' STUB_PRINTS=0.0.1
fails "a program that does not start fails" 'does not start' STUB_NOSTART=1
fails "an uninstall that fails fails" 'scoop uninstall probe failed' STUB_UNINSTALL_FAIL=1
fails "a clone in which the old manifest cannot be put fails" 'cannot be put in the clone' STUB_LOCK_ON_UNINSTALL=1
fails "an install of the old manifest that fails fails" 'scoop install of the manifest of' STUB_INSTALL_FAIL_NTH=2
fails "an old manifest that installs another version than its own fails" 'installed probe 9.9.9, not its 5.0.0' STUB_INSTALL_AS_NTH=2
fails "a clone in which the current manifest cannot be put back fails" 'cannot be put back' STUB_LOCK_ON_INSTALL_NTH=2
fails "an update that fails fails" 'scoop update probe failed' STUB_UPGRADE_FAIL=1
fails "an update that changes nothing fails" 'after scoop update probe is 5.0.0, not 6.0.0' STUB_UPGRADE_NOOP=1
fails "an update that leaves the old program in place fails" 'prints "probe 5.0.0"' STUB_UPGRADE_OLD_PROGRAM=1

plant 5.0.0 6.0.0; rm -rf "$T"; git clone -q --depth 1 "file://$R" "$T"
check "a clone of the bucket that has not the commit of the version before fetches it" "0" "$(run)"
plant 5.0.0 6.0.0; rm -rf "$T"; git clone -q --depth 1 "file://$R" "$T"; git -C "$T" remote set-url origin "$WORK/nowhere"
check "and one that cannot fetch it fails" "1" "$(run)"
check "and says the commit is not in the clone" "1" "$(said 'is not in the clone of the bucket')"
plant 4.0.0 5.0.0 6.0.0
check "the version before is the newest one below, not the oldest" "0" "$(run)"
check "and the update says it went from it" "1" "$(said 'went from 5.0.0 to 6.0.0')"

chmod -R u+w "$T" 2>/dev/null

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
