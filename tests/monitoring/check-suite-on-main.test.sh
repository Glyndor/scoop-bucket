#!/usr/bin/env bash
#
# Behaviour tests for the schedule and pull_request path of
# scripts/monitoring/check-suite-on-main.sh: the newest completed run on main is
# the verdict, a cancelled run is passed over, an empty history and a failing
# `gh` are reported and not passed, and the query asks for the right page.
#
# The fake `gh`, its builders and the runners come from
# tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: bash, coreutils, jq (for STUB_JSON).
set -u

# shellcheck source=tests/fixtures/monitoring/check-suite-on-main-fixture.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/fixtures/monitoring/check-suite-on-main-fixture.sh"

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

# --- any conclusion other than success is red -----------------------------
# Only the literal "success" passes. A check written as `= "failure"` would let
# timed_out, skipped, neutral, action_required and startup_failure through.
for concl in timed_out skipped neutral action_required startup_failure; do
	printf '%s' "$(schedule_response "$concl")" > "$WORK/resp"
	out="$(run_script)"; rc=$?
	check "a completed run concluded '$concl' fails" "1" "$rc"
done

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

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
