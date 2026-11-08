#!/usr/bin/env bash
#
# Behaviour tests for the ordering of the schedule path of
# scripts/monitoring/check-suite-on-main.sh: the page is not trusted to be
# sorted, cancelled runs are passed over, ties are broken by id and a run that
# is still in progress is not a verdict.
#
# The fake `gh`, its builders and the runners come from
# tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: bash, coreutils, jq (for STUB_JSON).
set -u

# shellcheck source=tests/fixtures/monitoring/check-suite-on-main-fixture.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/fixtures/monitoring/check-suite-on-main-fixture.sh"

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

# --- S7/S8: a run still in progress is not a verdict ---------------------
# The page asks for status=completed, but a run that is not completed has a
# null conclusion, an empty field in the record, and bash read collapses the
# tabs and shifts every field after it: a timestamp was reported as the
# conclusion and main as red over a green run.
page_s7=$(make_json_page \
	"$(make_json_run 2 b in_progress null "$ts_new"),$(make_json_run 1 a completed success "$ts_old")")
printf '%s' "$page_s7" > "$WORK/s7.json"
out="$(run_script_schedule_json "$WORK/s7.json")"; rc=$?
check "S7: an in_progress newest run does not hide the older completed success" "0" "$rc"
check "S7: names the completed run (#1) with conclusion=success" "1" \
	"$(printf '%s' "$out" | grep -c '#1 (event=push, conclusion=success')"
printf '%s' "$(make_json_page "$(make_json_run 2 b in_progress null "$ts_new")")" > "$WORK/s8.json"
out="$(run_script_schedule_json "$WORK/s8.json")"; rc=$?
check "S8: only an in_progress run on record fails" "1" "$rc"
check "S8: and says no completed run is on record" "1" \
	"$(printf '%s' "$out" | grep -c 'No completed run on record')"
# Control: the old filter, which does not ask for completed, must fail S7.
SCRIPT_OLD="$WORK/old-suite-on-main.sh"
python3 -I - "$SCRIPT" "$SCRIPT_OLD" <<'PY'
import sys
s = open(sys.argv[1]).read()
new = s.replace('map(select(.status == "completed")) as $done', 'map(.) as $done')
assert new != s
open(sys.argv[2], "w").write(new)
PY
SCRIPT_KEEP="$SCRIPT"; SCRIPT="$SCRIPT_OLD"
out="$(run_script_schedule_json "$WORK/s7.json")"; rc=$?
SCRIPT="$SCRIPT_KEEP"
check "S7 control: without the completed filter the same page is reported red" "1" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
