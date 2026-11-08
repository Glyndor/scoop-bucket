#!/usr/bin/env bash
#
# Behaviour tests for the schedule and pull_request path of
# scripts/monitoring/check-suite-on-main.sh: a transient gh failure is asked
# again, and one that never clears ends red. The push path always did this
# (check-suite-on-main-push.test.sh); this path made a single call, so one 502
# turned the twice-daily check red for nothing.
#
# The fake `gh`, its builders and the runners come from
# tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: bash, coreutils.
set -u

# shellcheck source=tests/fixtures/monitoring/check-suite-on-main-fixture.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/fixtures/monitoring/check-suite-on-main-fixture.sh"

pass=0
fail=0

# The fake gh answers call N with line N of the responses file, and logs each
# call NUL-terminated.
resp3() { printf '%s\n%s\n%s\n' "$(schedule_response success)" "$(schedule_response success)" "$(schedule_response success)" > "$WORK/resp"; }
calls() { tr -cd '\0' < "$WORK/gh.log" | wc -c; }

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

resp3
out="$(run_script)"; rc=$?
check "control: a scheduled run with no failing call is green" "0" "$rc"
check "control: and asked the API once" "1" "$(calls)"

resp3
out="$(STUB_FAIL_FIRST=1 run_script)"; rc=$?
check "one failing gh call is survived" "0" "$rc"
check "and it says it is asking again" "1" "$(printf '%s' "$out" | grep -c 'asking again')"
check "and waited before asking again" "1" "$(grep -c . "$WORK/sleep.log")"

resp3
out="$(STUB_FAIL_FIRST=2 run_script)"; rc=$?
check "two failing gh calls are survived" "0" "$rc"

resp3
out="$(STUB_FAIL_FIRST=99 run_script)"; rc=$?
check "a gh failure that never clears ends red" "1" "$rc"
check "and says there was no verdict" "1" "$(printf '%s' "$out" | grep -c 'no verdict on')"
check "and asked exactly three times" "3" "$(calls)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
