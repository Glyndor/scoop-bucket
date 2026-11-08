#!/usr/bin/env bash
#
# The shared fixture for the check-suite-on-main suites.
#
# It is sourced, not executed: it installs the fake `gh` and the fake `sleep` on
# PATH, the builders for the API answers, the runners of the script and the
# constants the cases read. It asserts nothing and prints no sentinel, because
# it is not a suite.
#
# Three suites source it:
#
#   tests/monitoring/check-suite-on-main.test.sh                          the schedule and pull_request path
#   tests/monitoring/check-suite-on-main/check-suite-on-main-push.test.sh   the push path
#   tests/monitoring/check-suite-on-main/check-suite-on-main-order.test.sh  ordering and cancelled runs
#
# The script's one dependency on the outside world is `gh`. A fake `gh` on PATH
# records the URL it was called with and serves a canned response, so the real
# shell runs against a deterministic API and no case that sources this file
# touches the network.
#
# Requires: bash, coreutils, jq (for STUB_JSON).

# shellcheck disable=SC2034 # the timestamps are read by the suites that source this file
# GitHub runners export GITHUB_EVENT_NAME, GITHUB_SHA, GITHUB_REPOSITORY and the script reads REPO; unset so each case that needs one sets it explicitly.
unset GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REPOSITORY REPO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/check-suite-on-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake `gh`. Appends its argv (NUL-separated) to STUB_LOG and serves a
# response. With STUB_JSON set, runs the script's --jq filter over the
# JSON file with real jq. Otherwise, takes line N of STUB_RESPONSES
# (1-indexed by call count). Same shape as the schedule-freshness stub
# so the two stay symmetrical.
write_stub() {
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${STUB_LOG:?stub log path required}"
idx=$(grep -cz . "$LOG" 2>/dev/null || true)
idx="${idx:-0}"
idx=$((idx + 1))
printf '%s\0' "$*" >> "$LOG"
if [ -n "${STUB_JSON:-}" ]; then
	filter=""; prev=""
	for arg in "$@"; do
		[ "$prev" = "--jq" ] && filter="$arg"
		prev="$arg"
	done
	json_path="$STUB_JSON"
	# STUB_JSON may name a file (one page, one response) or a directory
	# (one file per response, served in lexicographic order). The
	# push-path R6 case plants two pages, the schedule-path S5 a single
	# page; this lets both share the same helper without rebuilding the
	# stub per case.
	if [ -d "$json_path" ]; then
		file=$(ls -1 "$json_path" | sed -n "${idx}p")
		json_path="${json_path%/}/${file}"
	fi
	jq -r "$filter" "$json_path"
	exit "${STUB_EXIT_CODE:-0}"
fi
# STUB_FAIL_FIRST=N: the first N calls fail like a 502, whatever else is set.
if [ "$idx" -le "${STUB_FAIL_FIRST:-0}" ]; then
	echo "gh: HTTP 502" >&2
	exit 1
fi
RESP="${STUB_RESPONSES:?stub responses file required}"
val=$(awk -v n="$idx" 'NR==n {print; exit}' "$RESP")
printf '%s' "$val"
exit "${STUB_EXIT_CODE:-0}"
STUB
	chmod +x "$WORK/bin/gh"
	cat > "$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$*" >> "${SLEEP_LOG:?sleep log path required}"
STUB
	chmod +x "$WORK/bin/sleep"
}

REPO="owner/repo"
WF="tests.yml"

# Build the response that the schedule/pull_request path's filter
# produces. It carries the run's TSV plus a trailing count of cancelled
# runs skipped: id \t conclusion \t created_at \t html_url \t event \t
# skipped.
schedule_response() { # $1=conclusion [$2=event=push] [$3=id=1] [$4=skipped=0]
	local conclusion="$1" event="${2:-push}" id="${3:-1}" skipped="${4:-0}"
	local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '%s\t%s\t%s\thttps://github.com/%s/actions/runs/%s\t%s\t%s\n' \
		"$id" "$conclusion" "$ts" "$REPO" "$id" "$event" "$skipped"
}

# Build the response that the push path's filter produces: id \t status
# \t conclusion(or null) \t created_at \t html_url \t event \t head_sha.
push_response() { # $1=status $2=conclusion(or "null") $3=head_sha [$4=id=1] [$5=event=push]
	local status="$1" conclusion="$2" sha="$3" id="${4:-1}" event="${5:-push}"
	local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '%s\t%s\t%s\t%s\thttps://github.com/%s/actions/runs/%s\t%s\t%s\n' \
		"$id" "$status" "$conclusion" "$ts" "$REPO" "$id" "$event" "$sha"
}

# Filter output for an empty page: "EMPTY\t0".
empty_response() { printf 'EMPTY\t0\n'; }

# Filter output for a page where every completed run is cancelled:
# "EMPTY\tN", where N is the count of cancelled runs skipped.
no_verdict_response() { printf 'EMPTY\t1\n'; }

# Filter output for the push path when no run for GITHUB_SHA exists:
# "EMPTY" with no trailing fields.
empty_push_response() { printf 'EMPTY\n'; }

# Build a JSON object for one workflow run, the shape GitHub's API
# returns. The script's filter pulls id, status, conclusion,
# created_at, html_url, event, and head_sha from it. The literal
# "null" is emitted as a JSON null (no quotes) so the filter sees
# what an in-progress run looks like; anything else is a quoted
# string.
make_json_run() { # $1=id $2=head_sha $3=status $4=conclusion(or "null") $5=created_at [$6=event=push]
	local id="$1" sha="$2" status="$3" conclusion="$4" created="$5" event="${6:-push}"
	local conc
	if [ "$conclusion" = "null" ]; then
		conc="null"
	else
		conc="\"$conclusion\""
	fi
	printf '{"id":%s,"head_sha":"%s","status":"%s","conclusion":%s,"created_at":"%s","html_url":"https://github.com/%s/actions/runs/%s","event":"%s"}' \
		"$id" "$sha" "$status" "$conc" "$created" "$REPO" "$id" "$event"
}

# Wrap a comma-separated list of run objects in a workflow_runs page.
make_json_page() {
	printf '{"workflow_runs":[%s]}' "$1"
}

# Run the script with a fresh stub log on the schedule/pull_request
# path (no GITHUB_EVENT_NAME -> falls through to the existing path).
# The stub log is reset per call so each case starts at call index 1.
run_script() {
	rm -f "$WORK/gh.log" "$WORK/sleep.log"
	: >"$WORK/gh.log"
	: >"$WORK/sleep.log"
	STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$WORK/resp" \
		SLEEP_LOG="$WORK/sleep.log" \
		PATH="$WORK/bin:$PATH" \
		GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" \
		bash "$SCRIPT" 2>&1
}

# Run with STUB_RESPONSES on the push path (GITHUB_EVENT_NAME=push).
run_script_push() { # $1=GITHUB_SHA
	rm -f "$WORK/gh.log" "$WORK/sleep.log"
	: >"$WORK/gh.log"
	: >"$WORK/sleep.log"
	STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$WORK/resp" \
		SLEEP_LOG="$WORK/sleep.log" \
		PATH="$WORK/bin:$PATH" \
		GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" \
		GITHUB_EVENT_NAME=push GITHUB_SHA="$1" \
		bash "$SCRIPT" 2>&1
}

# Run with STUB_JSON on the push path. The script's filter runs over
# the JSON page with jq.
run_script_push_json() { # $1=JSON_file $2=GITHUB_SHA
	local json_file="$1" sha="$2"
	rm -f "$WORK/gh.log" "$WORK/sleep.log"
	: >"$WORK/gh.log"
	: >"$WORK/sleep.log"
	STUB_LOG="$WORK/gh.log" STUB_JSON="$json_file" \
		SLEEP_LOG="$WORK/sleep.log" \
		PATH="$WORK/bin:$PATH" \
		GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" \
		GITHUB_EVENT_NAME=push GITHUB_SHA="$sha" \
		bash "$SCRIPT" 2>&1
}

# Run with STUB_JSON on the schedule/pull_request path.
run_script_schedule_json() { # $1=JSON_file
	local json_file="$1"
	rm -f "$WORK/gh.log" "$WORK/sleep.log"
	: >"$WORK/gh.log"
	: >"$WORK/sleep.log"
	STUB_LOG="$WORK/gh.log" STUB_JSON="$json_file" \
		SLEEP_LOG="$WORK/sleep.log" \
		PATH="$WORK/bin:$PATH" \
		GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" \
		bash "$SCRIPT" 2>&1
}

write_stub

# Two timestamps, separated so each test can mix and match.
ts_old="2026-09-19T01:26:00Z"
ts_new="2026-09-19T15:22:53Z"
