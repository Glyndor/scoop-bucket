#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/check-schedule-history-ready.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() {
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail

if [ "${GH_FAIL:-}" = "1" ]; then
	echo "HTTP 503: service unavailable" >&2
	exit 1
fi
if [ "${GH_FAIL_ONCE:-}" = "1" ]; then
	state="${GH_STATE:-/tmp/check-schedule-history-ready-state}"
	if [ ! -e "$state" ]; then
		: > "$state"
		echo "HTTP 503: transient failure" >&2
		exit 1
	fi
fi
if [ "${GH_NOT_FOUND:-}" = "1" ]; then
	echo "HTTP 404: workflow published-bytes.yml not found on the default branch" >&2
	exit 1
fi
case "$*" in
	*"--event schedule"*"--status success"*)
		printf '%s\n' "${SCHEDULED_AT:-}"
		;;
	*)
		printf '%s\n' "${ANY_AT:-}"
		;;
esac
GH
chmod +x "$WORK/bin/gh"

make_repo() {
	local path="$1"
	local committed_at="$2"
	mkdir -p "$path/.github/workflows"
	git -C "$path" init -q -b main
	git -C "$path" config user.name test
	git -C "$path" config user.email test@example.invalid
	printf 'name: test\n' > "$path/.github/workflows/published-bytes.yml"
	GIT_AUTHOR_DATE="$committed_at" GIT_COMMITTER_DATE="$committed_at" \
		git -C "$path" add .
	GIT_AUTHOR_DATE="$committed_at" GIT_COMMITTER_DATE="$committed_at" \
		git -C "$path" commit -qm fixture
}

make_repo "$WORK/recent" "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)"
make_repo "$WORK/old" "$(date -u -d '4 days ago' +%Y-%m-%dT%H:%M:%SZ)"

run() {
	local path="$1"
	(
		cd "$path" || exit 1
		PATH="$WORK/bin:$PATH" \
			REPO="Glyndor/scoop-bucket" \
			RETRY_DELAY_SECONDS=0 \
			GH_STATE="$WORK/gh-state" \
			bash "$SCRIPT" published-bytes.yml 3
	)
}

check "a successful scheduled run makes the watcher ready" "ready=true" \
	"$(SCHEDULED_AT=2026-11-01T00:00:00Z run "$WORK/recent")"
check "a new workflow without scheduled history stays not ready" "ready=false" \
	"$(run "$WORK/recent")"
check "an old workflow without scheduled history becomes ready to fail" "ready=true" \
	"$(run "$WORK/old")"
# Added ten days ago, deleted, added again yesterday: the grace is counted from the
# re-add, since the cron has had no time to fire since the workflow came back.
make_repo "$WORK/readded" "$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
git -C "$WORK/readded" rm -q .github/workflows/published-bytes.yml
GIT_AUTHOR_DATE="$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" GIT_COMMITTER_DATE="$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
	git -C "$WORK/readded" commit -qm removed
mkdir -p "$WORK/readded/.github/workflows"
printf 'name: test\n' > "$WORK/readded/.github/workflows/published-bytes.yml"
git -C "$WORK/readded" add .
GIT_AUTHOR_DATE="$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)" GIT_COMMITTER_DATE="$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)" \
	git -C "$WORK/readded" commit -qm readded
check "a workflow added again yesterday is still in its grace period" "ready=false" \
	"$(run "$WORK/readded")"
check "a workflow absent from the default branch is not ready" "ready=false" \
	"$(GH_NOT_FOUND=1 run "$WORK/recent")"
mkdir -p "$WORK/deleted/.github/workflows"
git -C "$WORK/deleted" init -q -b main
git -C "$WORK/deleted" config user.name test
git -C "$WORK/deleted" config user.email test@example.invalid
printf 'name: test\n' > "$WORK/deleted/.github/workflows/other.yml"
git -C "$WORK/deleted" add .
git -C "$WORK/deleted" commit -qm fixture
check "a workflow deleted from the checkout becomes ready to fail" "ready=true" \
	"$(GH_NOT_FOUND=1 run "$WORK/deleted")"
check "an API failure is reported" "1" \
	"$(GH_FAIL=1 run "$WORK/recent" >/dev/null 2>&1; printf '%s' "$?")"
check "a transient API failure is retried" "ready=true" \
	"$(GH_FAIL_ONCE=1 SCHEDULED_AT=2026-11-01T00:00:00Z run "$WORK/recent")"

workflow="$HERE/.github/workflows/freshness.yml"
# shellcheck disable=SC2016 # the workflow's literal shell is under test
output_line="$(grep -F 'echo "$ready" >> "$GITHUB_OUTPUT"' "$workflow")"
# shellcheck disable=SC2016 # the workflow's literal shell is under test
check "the workflow writes the helper output verbatim" "1" \
	"$(printf '%s\n' "$output_line" | grep -c 'echo "\$ready" >> "\$GITHUB_OUTPUT"')"
readiness="$(awk '/^  [a-z0-9-]+:$/ { p = ($0 == "  published-bytes-ready:") } p' "$workflow")"
check "the readiness checkout has full history" "1" \
	"$(grep -c 'fetch-depth: 0' <<<"$readiness")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
