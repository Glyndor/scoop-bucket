#!/usr/bin/env bash
#
# Tests for scripts/check-suite-on-main.sh -- the watcher that reports
# when the newest completed run of the suite workflow on `main` is red.
#
# The script depends on GH_TOKEN, REPO and WORKFLOW from the
# environment; the only network call is `gh api ... --jq ...`. A fake
# `gh` on PATH records the URL it was called with and serves a canned
# response, so the cases below exercise the real shell with a
# deterministic API rather than mocking the script itself. A fake
# `sleep` records its argument and returns at once, so the push path's
# retry budget is exercised in milliseconds rather than minutes.
#
# Two stubs, one assertion each:
#   - STUB_RESPONSES: one TSV line per call (the filter's final output)
#   - STUB_JSON: a JSON page the script's --jq filter runs over with jq
#
# Three paths the gate answers:
#   - schedule and pull_request: newest completed run on main, page of
#     30, sorted by created_at desc here, cancelled runs passed over.
#   - push: the run whose head_sha is GITHUB_SHA; wait up to 32 attempts
#     of 15 seconds for it to complete.
#
# Plus the URL contract (branch=main AND status=completed on
# schedule/PR, per_page=30 on both, one call on schedule/PR), the
# API-error shape (a failing `gh` is not the same as an empty
# history), and the 2026-09-19 fix that makes the push path ask for
# the run for THIS commit rather than whichever run happens to sit at
# the head of the page.
#
# Requires: bash, coreutils, jq (for STUB_JSON).
set -u

# GitHub runners export GITHUB_EVENT_NAME, GITHUB_SHA, GITHUB_REPOSITORY and the script reads REPO; unset so each case that needs one sets it explicitly.
unset GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REPOSITORY REPO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/check-suite-on-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
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

# --- schedule / pull_request path: existing cases ----------------------

# --- a completed successful run is silent -------------------------------
printf '%s' "$(schedule_response success)" > "$WORK/resp"
out="$(run_script)"; rc=$?
check "a completed successful run passes" "0" "$rc"
check "and the success line names the workflow" "1" \
	"$(printf '%s' "$out" | grep -q "Newest completed run of ${WF} on main" && echo 1 || echo 0)"
check "and reports the conclusion it saw" "1" \
	"$(printf '%s' "$out" | grep -q 'conclusion=success' && echo 1 || echo 0)"
check "and prints a clickable link to the run" "1" \
	"$(printf '%s' "$out" | grep -q "https://github.com/${REPO}/actions/runs/1" && echo 1 || echo 0)"
check "and ends with the success summary" "1" \
	"$(printf '%s' "$out" | grep -q 'Newest completed run on main concluded success.' && echo 1 || echo 0)"

# --- a completed failing run is reported, with a link -------------------
printf '%s' "$(schedule_response failure)" > "$WORK/resp"
out="$(run_script)"; rc=$?
check "a completed failing run fails" "1" "$rc"
check "and the error names the workflow file" "1" \
	"$(printf '%s' "$out" | grep -q "${WF} is red on main" && echo 1 || echo 0)"
check "and the error names the conclusion it saw (failure)" "1" \
	"$(printf '%s' "$out" | grep -q "concluded 'failure'" && echo 1 || echo 0)"
check "and the error links to the failing run" "1" \
	"$(printf '%s' "$out" | grep -q "https://github.com/${REPO}/actions/runs/1" && echo 1 || echo 0)"
check "and is not the empty-history error" "0" \
	"$(printf '%s' "$out" | grep -c 'No completed run on record')"

# --- a page where every completed run is cancelled fails as no verdict -
#
# Cancelled runs alone don't answer the gate: a newer push
# (pull_request) or an in-flight rerun (schedule) is the only reason a
# completed run is cancelled. When the whole page is cancelled, the
# gate cannot tell what the suite verdict is, so it fails with the
# no-verdict message rather than reading the cancelled conclusion as
# red. The push path keeps cancelled as red, because nothing newer can
# answer for THAT commit; the schedule/PR path passes cancelled over.
printf '%s' "$(no_verdict_response)" > "$WORK/resp"
out="$(run_script)"; rc=$?
check "a page of one cancelled run fails" "1" "$rc"
check "and reports the no-verdict message" "1" \
	"$(printf '%s' "$out" | grep -q 'No verdict on' && echo 1 || echo 0)"
check "and names how many runs were passed over" "1" \
	"$(printf '%s' "$out" | grep -q '1 passed over' && echo 1 || echo 0)"
check "and is not the existing conclusion-failure error" "0" \
	"$(printf '%s' "$out" | grep -c "is red on main")"

# --- empty history is reported, not passed silently --------------------
#
# A workflow whose first run on main is still queued must read as red;
# "we cannot tell" is the same as "we cannot trust green". Without
# this case the gate would be happy with a response shape that always
# agrees.
printf '%s' "$(empty_response)" > "$WORK/resp"
out="$(run_script)"; rc=$?
check "an empty history fails" "1" "$rc"
check "and the error says 'No completed run on record'" "1" \
	"$(printf '%s' "$out" | grep -q 'No completed run on record' && echo 1 || echo 0)"
check "and the error names the workflow file" "1" \
	"$(printf '%s' "$out" | grep -q "No completed run on record for ${WF}" && echo 1 || echo 0)"
check "and is not the conclusion-failure error" "0" \
	"$(printf '%s' "$out" | grep -c 'is red on main')"
check "and is not the no-verdict error" "0" \
	"$(printf '%s' "$out" | grep -c 'No verdict on')"

# --- a failing `gh` must fail the step, not be read as empty ------------
#
# `set -euo pipefail` is supposed to carry a non-zero `gh` through. An
# API error stops the job rather than being read as "no result", which
# would be reported as a missing run and send someone looking for the
# wrong thing.
printf '%s' "$(schedule_response success)" > "$WORK/resp"
out="$(STUB_EXIT_CODE=1 run_script)"; rc=$?
check "a failing gh api call fails the step" "1" \
	"$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and does not report it as no completed run" "0" \
	"$(printf '%s' "$out" | grep -c 'No completed run on record')"
check "and does not report it as a red run either" "0" \
	"$(printf '%s' "$out" | grep -c 'is red on main')"

# --- the URL filters by branch=main AND status=completed -----------------
#
# Without branch=main the gate would happily report a pull-request run
# as the suite's verdict on main; without status=completed it would
# panic at an in-progress run, which is exactly the case the brief
# says is not a failure.
printf '%s' "$(schedule_response success)" > "$WORK/resp"
run_script >/dev/null
check "the URL contains branch=main" "1" \
	"$(grep -acz 'branch=main' "$WORK/gh.log" | tr -d ' ')"
check "the URL contains status=completed" "1" \
	"$(grep -acz 'status=completed' "$WORK/gh.log" | tr -d ' ')"
check "the URL targets the right workflow file" "1" \
	"$(grep -acz "workflows/${WF}/runs" "$WORK/gh.log" | tr -d ' ')"
check "and made exactly one API call (per_page=30, no paging)" "1" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"

# --- the watcher names the trigger event it saw -------------------------
#
# The script reads .event so the message can say "schedule" or "push"
# next to the conclusion. A gate that flattened the event field would
# make the log harder to read, but it would still pass the cases
# above, so this is here as its own assertion.
printf '%s' "$(schedule_response failure schedule)" > "$WORK/resp"
out="$(run_script)"
check "and the success line names the event (schedule)" "1" \
	"$(printf '%s' "$out" | grep -q 'event=schedule' && echo 1 || echo 0)"

# --- the schedule/pull_request query asks for per_page=30 (S4) ---------
#
# The page has to be big enough that a flurry of runs from one push
# does not push the next push's verdict out of view. S4 reads the
# logged call to assert the URL is what was actually asked for, not
# what the script source happens to contain.
printf '%s' "$(schedule_response success)" > "$WORK/resp"
run_script >/dev/null
check "S4: the URL asks for per_page=30" "1" \
	"$(grep -acz 'per_page=30' "$WORK/gh.log" | tr -d ' ')"

# --- push path: the URL filters by head_sha=GITHUB_SHA (R7) ------------
#
# The push path must ask the API for THIS commit's runs, so 30 or more
# newer runs on the branch (re-runs of older commits) cannot push
# GITHUB_SHA off the page. The jq select stays as a second guard, but
# the URL filter is what makes the listing small enough to read. Same
# pattern as S4: read the logged call to assert the URL is what was
# actually asked for, not what the script source happens to contain.
printf '%s' "$(push_response completed success b 2)" > "$WORK/resp"
out="$(run_script_push b)"; rc=$?
check "R7: passes on a single completed run for b" "0" "$rc"
check "R7: the URL contains branch=main" "1" \
	"$(grep -acz 'branch=main' "$WORK/gh.log" | tr -d ' ')"
check "R7: the URL contains head_sha=b" "1" \
	"$(grep -acz 'head_sha=b' "$WORK/gh.log" | tr -d ' ')"
check "R7: the URL contains per_page=30" "1" \
	"$(grep -acz 'per_page=30' "$WORK/gh.log" | tr -d ' ')"

# --- push path: GITHUB_SHA empty refuses, does not fall through ----------
#
# A push event with no SHA has nothing for the gate to answer for; the
# schedule path would happily report a different commit's run as
# green, so the script must refuse loudly instead. The error uses
# ::error:: so a reader of the log sees the failure for what it is,
# not a bash diagnostic prefixed with the script's path.
: >"$WORK/gh.log"
: >"$WORK/sleep.log"
out="$(GITHUB_EVENT_NAME=push GITHUB_SHA= \
	STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$WORK/resp" \
	SLEEP_LOG="$WORK/sleep.log" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" \
	bash "$SCRIPT" 2>&1)"; rc=$?
check "R8: push with empty GITHUB_SHA fails" "1" "$rc"
check "R8: the failure carries an ::error:: annotation" "1" \
	"$(printf '%s' "$out" | grep -q '^::error::' && echo 1 || echo 0)"
check "R8: the error names GITHUB_SHA" "1" \
	"$(printf '%s' "$out" | grep -q 'GITHUB_SHA' && echo 1 || echo 0)"
check "R8: did not call the API at all" "0" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "R8: did not sleep either" "0" \
	"$(grep -acz . "$WORK/sleep.log" 2>/dev/null | tr -d ' ')"

# --- push path ---------------------------------------------------------
#
# The defects of 2026-09-19 lived here. The script ran at the same
# moment as the `tests.yml` run for the commit being pushed, asked for
# the newest COMPLETED `tests.yml` run on `main`, and read whichever
# run happened to be at the head of the page, which on that push
# was the previous commit's still-red run. The push path now asks the
# question this commit's run has to answer: the run whose head_sha is
# GITHUB_SHA. Cases R1-R5 pin each shape of the fix.

# Two timestamps, separated so each test can mix and match.
ts_old="2026-09-19T01:26:00Z"
ts_new="2026-09-19T15:22:53Z"

# --- R1: a page with older failure (a) and newer success (b); a FIRST ---
#
# The 2026-09-19 race. GITHUB_SHA=b. The page has an older, completed
# failure run for a placed FIRST in the page, and a newer, completed
# success run for b. The script sorts by created_at desc and picks the
# head where head_sha=b, so the verdict is success and the output
# names the run for b, not the one for a.
page_ab=$(make_json_page \
	"$(make_json_run 1 a completed failure "$ts_old"),$(make_json_run 2 b completed success "$ts_new")")
printf '%s' "$page_ab" > "$WORK/r1.json"
out="$(run_script_push_json "$WORK/r1.json" b)"; rc=$?
check "R1: a page with a older and b newer passes for GITHUB_SHA=b" "0" "$rc"
check "R1: names the run for b (#2)" "1" \
	"$(printf '%s' "$out" | grep -q '#2' && echo 1 || echo 0)"
check "R1: does not name the run for a (#1)" "0" \
	"$(printf '%s' "$out" | grep -c '#1')"
check "R1: makes exactly one API call (no retry)" "1" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"

# --- R2: in_progress on first call, completed success on second --------
#
# GITHUB_SHA=b. The first attempt finds the run for b still in
# progress; the script sleeps 15 seconds and asks again. The second
# attempt finds it completed success. Exactly one sleep of 15.
printf '%s\n%s\n' \
	"$(push_response in_progress null b 2)" \
	"$(push_response completed success b 2)" > "$WORK/resp"
out="$(run_script_push b)"; rc=$?
check "R2: in_progress then success passes" "0" "$rc"
check "R2: makes exactly 2 API calls" "2" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "R2: sleeps exactly once" "1" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "R2: the single sleep argument is 15" "15" \
	"$(awk -v RS='\0' '{print}' "$WORK/sleep.log" | sort -u)"

# --- R3: completed failure for b fails with that run named -------------
printf '%s' "$(push_response completed failure b 2)" > "$WORK/resp"
out="$(run_script_push b)"; rc=$?
check "R3: completed failure fails" "1" "$rc"
check "R3: names the conclusion it saw (failure)" "1" \
	"$(printf '%s' "$out" | grep -q "concluded 'failure'" && echo 1 || echo 0)"
check "R3: names the run for b (#2)" "1" \
	"$(printf '%s' "$out" | grep -q '#2' && echo 1 || echo 0)"

# --- R4: no run for b in any of 32 responses -> fail after 8 minutes ---
#
# 32 attempts saw nothing for THIS commit. The script fails with one
# line naming the commit and 8 minutes, rather than reading another
# commit's run, the failure 2026-09-19 measured. 32 attempts at
# 15 s each means 31 sleeps between attempts and none after the
# last, so the assertion is "exactly 31 sleeps".
: > "$WORK/resp"
for _ in $(seq 1 32); do
	printf '%s' "$(empty_push_response)" >> "$WORK/resp"
	printf '\n' >> "$WORK/resp"
done
out="$(run_script_push b)"; rc=$?
check "R4: no run for b in 32 attempts fails" "1" "$rc"
check "R4: makes exactly 32 API calls" "32" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "R4: sleeps exactly 31 times" "31" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "R4: every sleep argument is 15" "15" \
	"$(awk -v RS='\0' '{print}' "$WORK/sleep.log" | sort -u)"
check "R4: names commit b in the failure" "1" \
	"$(printf '%s' "$out" | grep -qF 'commit b' && echo 1 || echo 0)"
check "R4: says 8 minutes" "1" \
	"$(printf '%s' "$out" | grep -q '8 minutes' && echo 1 || echo 0)"
check "R4: does not name any other run's conclusion as the verdict" "0" \
	"$(printf '%s' "$out" | grep -cE "concluded '(success|failure)'")"

# --- R5: a cancelled run for b is red ----------------------------------
#
# A cancelled run for THIS commit means a newer push superseded it;
# that newer push gets its own check, but for THIS push the verdict
# on record is "no", so red it is. The schedule/pull_request path
# treats cancelled as a superseded-run signal and passes it over; the
# push path keeps cancelled as red because nothing newer can answer
# for the pushed commit.
printf '%s' "$(push_response completed cancelled b 2)" > "$WORK/resp"
out="$(run_script_push b)"; rc=$?
check "R5: a cancelled run for b fails" "1" "$rc"
check "R5: names the conclusion it saw (cancelled)" "1" \
	"$(printf '%s' "$out" | grep -q "concluded 'cancelled'" && echo 1 || echo 0)"

# --- R6: an older a-failure beside a newer b-in_progress; b finishes -----
#
# The race measured on 2026-09-19, pinned next to R2 because both
# cases have a first call that finds b still in_progress. On that
# push, when this gate fired, the tests.yml run for b was still
# IN PROGRESS and the previous commit's run for a was already
# COMPLETED with failure. A script that reads "the newest completed
# run" instead of "the run for this commit" passes every case above:
# every existing push-path case has the pushed commit's run either
# already completed or alone on the page. Two attempts, two truths
# per attempt: the first serves the exact 2026-09-19 page (a older
# failure at the head of the completed tail, b newer and still
# in_progress); the second serves b as completed success. The script
# must wait one sleep of 15 seconds for b, then read b as the
# verdict; an older a-failure must not bleed through as the answer
# for this commit.
mkdir -p "$WORK/r6"
page_r6_1=$(make_json_page \
	"$(make_json_run 100 a completed failure "$ts_old"),$(make_json_run 200 b in_progress null "$ts_new")")
printf '%s' "$page_r6_1" > "$WORK/r6/1.json"
page_r6_2=$(make_json_page \
	"$(make_json_run 200 b completed success "$ts_new")")
printf '%s' "$page_r6_2" > "$WORK/r6/2.json"
out="$(run_script_push_json "$WORK/r6" b)"; rc=$?
check "R6: older a-failure does not bleed into b verdict" "0" "$rc"
check "R6: makes exactly 2 API calls" "2" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "R6: sleeps exactly once" "1" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "R6: the single sleep argument is 15" "15" \
	"$(awk -v RS='\0' '{print}' "$WORK/sleep.log" | sort -u)"
check "R6: names the b run (#200)" "1" \
	"$(printf '%s' "$out" | grep -q '#200' && echo 1 || echo 0)"
check "R6: does not name the a run (#100)" "0" \
	"$(printf '%s' "$out" | grep -c '#100')"
check "R6: does not call out main as red" "0" \
	"$(printf '%s' "$out" | grep -c 'main is red')"

# --- schedule path: ordering and cancelled handling (S1-S5) ------------
#
# The schedule path does not trust the order of the page. S1 plants
# an unsorted page with the older success first and the newer
# failure second; the script sorts by created_at desc and reports the
# failure. S2 plants a page where the newest is cancelled and the next
# is success; the script skips the cancelled and passes, with the
# count printed. S3 plants a page where every completed run is
# cancelled; the script fails with the no-verdict message. S5 plants
# three completed runs where the newest sits in the middle of the
# page so neither the first nor the last item is the answer; only
# the sort picks the 12:00 failure.

# --- S1: unsorted page, older success first, newer failure second ------
page_s1=$(make_json_page \
	"$(make_json_run 1 a completed success "$ts_old"),$(make_json_run 2 b completed failure "$ts_new")")
printf '%s' "$page_s1" > "$WORK/s1.json"
out="$(run_script_schedule_json "$WORK/s1.json")"; rc=$?
check "S1: unsorted page, newer failure wins" "1" "$rc"
check "S1: names the newer run (#2)" "1" \
	"$(printf '%s' "$out" | grep -q '#2' && echo 1 || echo 0)"
check "S1: reports conclusion=failure" "1" \
	"$(printf '%s' "$out" | grep -q 'conclusion=failure' && echo 1 || echo 0)"

# --- S2: newest completed is cancelled, next is success ----------------
page_s2=$(make_json_page \
	"$(make_json_run 1 a completed cancelled "$ts_new"),$(make_json_run 2 b completed success "$ts_old")")
printf '%s' "$page_s2" > "$WORK/s2.json"
out="$(run_script_schedule_json "$WORK/s2.json")"; rc=$?
check "S2: newest cancelled then success passes" "0" "$rc"
check "S2: says 1 cancelled run was passed over" "1" \
	"$(printf '%s' "$out" | grep -q '1 cancelled run(s) passed over' && echo 1 || echo 0)"

# --- S3: every completed run is cancelled ------------------------------
page_s3=$(make_json_page \
	"$(make_json_run 1 a completed cancelled "$ts_old"),$(make_json_run 2 b completed cancelled "$ts_new")")
printf '%s' "$page_s3" > "$WORK/s3.json"
out="$(run_script_schedule_json "$WORK/s3.json")"; rc=$?
check "S3: every run cancelled fails" "1" "$rc"
check "S3: reports the no-verdict message" "1" \
	"$(printf '%s' "$out" | grep -q 'No verdict on' && echo 1 || echo 0)"
check "S3: does not report the cancelled conclusion as red" "0" \
	"$(printf '%s' "$out" | grep -c "concluded 'cancelled'")"

# --- S5: newest completed run sits in the MIDDLE of an unsorted page ----
#
# Without the sort, a script that takes the last item of the page
# picks the 08:00 success and passes; one that takes the first picks
# the 10:00 success and passes. The newest is in the middle so neither
# "first item" nor "last item" is the answer; only sorting by
# created_at desc and picking the head names the 12:00 failure.
page_s5=$(make_json_page \
	"$(make_json_run 10 a completed success 2026-09-19T10:00:00Z),$(make_json_run 12 b completed failure 2026-09-19T12:00:00Z),$(make_json_run 8 c completed success 2026-09-19T08:00:00Z)")
printf '%s' "$page_s5" > "$WORK/s5.json"
out="$(run_script_schedule_json "$WORK/s5.json")"; rc=$?
check "S5: newest in the middle fails" "1" "$rc"
check "S5: names the 12:00 run (#12)" "1" \
	"$(printf '%s' "$out" | grep -q '#12' && echo 1 || echo 0)"
check "S5: does not name the 10:00 run (#10)" "0" \
	"$(printf '%s' "$out" | grep -c '#10')"
check "S5: does not name the 08:00 run (#8)" "0" \
	"$(printf '%s' "$out" | grep -c '#8')"

# --- S6: two runs share created_at; id is the tie-break, not order ------
#
# When two completed runs share the same created_at (a re-run landing
# in the same second, or two runs the API happens to serve adjacent),
# the verdict must not depend on which one the API happens to list
# first. The script sorts by [created_at, id] desc and picks the head,
# so the higher id wins regardless of page order. Both orderings are
# tried: lower id success first, then higher id failure; and the
# reverse. The verdict is the failure's in both cases.
ts_tie="2026-09-19T12:00:00Z"
page_s6_lo=$(make_json_page \
	"$(make_json_run 100 a completed success "$ts_tie"),$(make_json_run 200 b completed failure "$ts_tie")")
printf '%s' "$page_s6_lo" > "$WORK/s6_lo.json"
out="$(run_script_schedule_json "$WORK/s6_lo.json")"; rc=$?
check "S6 (lower-id first): the higher-id run wins" "1" "$rc"
check "S6 (lower-id first): names the #200 run" "1" \
	"$(printf '%s' "$out" | grep -q '#200' && echo 1 || echo 0)"
check "S6 (lower-id first): does not name the #100 run" "0" \
	"$(printf '%s' "$out" | grep -c '#100')"
check "S6 (lower-id first): reports conclusion=failure" "1" \
	"$(printf '%s' "$out" | grep -q 'conclusion=failure' && echo 1 || echo 0)"
page_s6_hi=$(make_json_page \
	"$(make_json_run 200 b completed failure "$ts_tie"),$(make_json_run 100 a completed success "$ts_tie")")
printf '%s' "$page_s6_hi" > "$WORK/s6_hi.json"
out="$(run_script_schedule_json "$WORK/s6_hi.json")"; rc=$?
check "S6 (higher-id first): the higher-id run still wins" "1" "$rc"
check "S6 (higher-id first): names the #200 run" "1" \
	"$(printf '%s' "$out" | grep -q '#200' && echo 1 || echo 0)"
check "S6 (higher-id first): does not name the #100 run" "0" \
	"$(printf '%s' "$out" | grep -c '#100')"
check "S6 (higher-id first): reports conclusion=failure" "1" \
	"$(printf '%s' "$out" | grep -q 'conclusion=failure' && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
