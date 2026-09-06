#!/usr/bin/env bash
#
# Tests for scripts/check-suite-on-main.sh -- the watcher that reports
# when the newest completed run of the suite workflow on `main` is red.
#
# The script depends on GH_TOKEN, REPO and WORKFLOW from the
# environment; the only network call is `gh api ... --jq ...`. A fake
# `gh` on PATH records the URL it was called with and serves a canned
# response, so the cases below exercise the real shell with a
# deterministic API rather than mocking the script itself.
#
# Three planted answers distinguish the gate:
#   - a completed successful run  -> silent (exit 0)
#   - a completed failing run     -> red, named run, link to it
#   - an empty history            -> red, says it found nothing
# Plus the URL contract (branch=main AND status=completed, one call,
# targets the right workflow file), and the API-error shape (a failing
# `gh` is not the same as an empty history).
#
# Requires: bash, coreutils.
set -u

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

# Fake `gh`. Appends its argv (NUL-separated) to STUB_LOG and prints
# line N of STUB_RESPONSES, where N is the call count. An empty line
# is exactly what `gh --jq 'if ... then "EMPTY" else ... end'`
# produces when the workflow_runs array is empty. Same shape as the
# schedule-freshness stub so the two stay symmetrical.
write_stub() {
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${STUB_LOG:?stub log path required}"
RESP="${STUB_RESPONSES:?stub responses file required}"
idx=$(grep -cz . "$LOG" 2>/dev/null || true)
idx="${idx:-0}"
idx=$((idx + 1))
printf '%s\0' "$*" >> "$LOG"
val=$(awk -v n="$idx" 'NR==n {print; exit}' "$RESP")
printf '%s' "$val"
exit "${STUB_EXIT_CODE:-0}"
STUB
	chmod +x "$WORK/bin/gh"
}

REPO="owner/repo"
WF="tests.yml"

# Build a response that looks exactly like the jq @tsv output the
# script expects: id \t conclusion \t created_at \t html_url \t event.
# The shape is what tests, not just the values.
run_response() { # $1=conclusion [$2=event=push] [$3=id=1]
	local conclusion="$1" event="${2:-push}" id="${3:-1}"
	local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '%s\t%s\t%s\thttps://github.com/%s/actions/runs/%s\t%s\n' \
		"$id" "$conclusion" "$ts" "$REPO" "$id" "$event"
}

empty_response() { printf 'EMPTY\n'; }

# Run the script with a fresh stub log and the given response. The
# stub log is reset per call so each case starts at call index 1.
run_script() { # $1=response string
	rm -f "$WORK/gh.log"
	STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$WORK/resp" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" \
	bash "$SCRIPT" 2>&1
}

write_stub

# --- a completed successful run is silent --------------------------------
printf '%s' "$(run_response success)" > "$WORK/resp"
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

# --- a completed failing run is reported, with a link --------------------
printf '%s' "$(run_response failure)" > "$WORK/resp"
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

# --- a cancelled run also fails (anything but success is red) ------------
#
# Without this, the failure case could be satisfied by a script that
# only knows about "success" and "failure" and otherwise returns red.
# The brief says the gate fails when conclusion is not success, full
# stop: cancelled, timed_out, action_required, neutral, skipped all
# read as red.
printf '%s' "$(run_response cancelled)" > "$WORK/resp"
out="$(run_script)"; rc=$?
check "a cancelled run fails too" "1" "$rc"
check "and the error names the conclusion it saw (cancelled)" "1" \
	"$(printf '%s' "$out" | grep -q "concluded 'cancelled'" && echo 1 || echo 0)"

# --- empty history is reported, not passed silently ----------------------
#
# The third planted answer. A workflow whose first run on main is
# still queued must read as red; "we cannot tell" is the same as
# "we cannot trust green". Without this case the gate would be happy
# with a response shape that always agrees.
printf '%s' "$(empty_response)" > "$WORK/resp"
out="$(run_script)"; rc=$?
check "an empty history fails" "1" "$rc"
check "and the error says 'No completed run on record'" "1" \
	"$(printf '%s' "$out" | grep -q 'No completed run on record' && echo 1 || echo 0)"
check "and the error names the workflow file" "1" \
	"$(printf '%s' "$out" | grep -q "No completed run on record for ${WF}" && echo 1 || echo 0)"
check "and is not the conclusion-failure error" "0" \
	"$(printf '%s' "$out" | grep -c 'is red on main')"

# --- a failing `gh` must fail the step, not be read as empty ------------
#
# `set -euo pipefail` is supposed to carry a non-zero `gh` through. An
# API error stops the job rather than being read as "no result", which
# would be reported as a missing run and send someone looking for the
# wrong thing.
printf '%s' "$(run_response success)" > "$WORK/resp"
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
printf '%s' "$(run_response success)" > "$WORK/resp"
run_script >/dev/null
check "the URL contains branch=main" "1" \
	"$(grep -acz 'branch=main' "$WORK/gh.log" | tr -d ' ')"
check "the URL contains status=completed" "1" \
	"$(grep -acz 'status=completed' "$WORK/gh.log" | tr -d ' ')"
check "the URL targets the right workflow file" "1" \
	"$(grep -acz "workflows/${WF}/runs" "$WORK/gh.log" | tr -d ' ')"
check "and made exactly one API call (per_page=1, no paging)" "1" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"

# --- the watcher names the trigger event it saw --------------------------
#
# The script reads .event so the message can say "schedule" or "push"
# next to the conclusion. A gate that flattened the event field would
# make the log harder to read, but it would still pass the cases
# above, so this is here as its own assertion.
printf '%s' "$(run_response failure schedule)" > "$WORK/resp"
out="$(run_script)"
check "and the success line names the event (schedule)" "1" \
	"$(printf '%s' "$out" | grep -q 'event=schedule' && echo 1 || echo 0)"

# --- the gate covers itself: passing against this repository -------------
#
# The script lives in scripts/, so the test-coverage gate asserts a
# matching test exists. The test that proves it has two halves: this
# file is present, and the script above runs against the repo as the
# test-coverage suite invokes it. The second half is implicit because
# the cases above are the test.
check "the watcher has a test in tests/" "1" \
	"$(test -f "$HERE/tests/check-suite-on-main.test.sh" && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
