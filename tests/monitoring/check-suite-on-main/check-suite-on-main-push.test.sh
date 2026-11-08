#!/usr/bin/env bash
#
# Behaviour tests for the push path of scripts/monitoring/check-suite-on-main.sh:
# the verdict is the run whose head_sha is GITHUB_SHA, polled for up to 20 minutes
# while it is not completed, and a cancelled run for that commit is red.
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

# --- a transient gh failure on the push path is asked again -------------
# One 502 must not end a poll that has 79 attempts left; a failure that never
# clears must still end red, not green.
printf '%s\n%s\n' "$(push_response completed success abc123)" "$(push_response completed success abc123)" > "$WORK/resp"
out="$(STUB_FAIL_FIRST=1 run_script_push abc123)"; rc=$?
check "a push poll survives one failing gh call" "0" "$rc"
check "and says it is asking again" "1" "$(printf '%s' "$out" | grep -c 'asking again')"
printf '%s\n' "$(push_response completed success abc123)" > "$WORK/resp"
out="$(STUB_FAIL_FIRST=99 run_script_push abc123)"; rc=$?
check "a gh failure that never clears ends red" "1" "$rc"

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
# shellcheck disable=SC1007 # GITHUB_SHA='' is set empty on purpose, so the script must refuse.
out="$(GITHUB_EVENT_NAME=push GITHUB_SHA="" \
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

# --- R4: no run for b in any of 80 responses -> fail after 20 minutes ---
#
# 80 attempts saw nothing for THIS commit. The script fails with one
# line naming the commit and 20 minutes, rather than reading another
# commit's run, the failure 2026-09-19 measured. 80 attempts at
# 15 s each means 79 sleeps between attempts and none after the
# last, so the assertion is "exactly 79 sleeps".
: > "$WORK/resp"
for _ in $(seq 1 80); do
	printf '%s' "$(empty_push_response)" >> "$WORK/resp"
	printf '\n' >> "$WORK/resp"
done
out="$(run_script_push b)"; rc=$?
check "R4: no run for b in 80 attempts fails" "1" "$rc"
check "R4: makes exactly 80 API calls" "80" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "R4: sleeps exactly 79 times" "79" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "R4: every sleep argument is 15" "15" \
	"$(awk -v RS='\0' '{print}' "$WORK/sleep.log" | sort -u)"
check "R4: names commit b in the failure" "1" \
	"$(printf '%s' "$out" | grep -qF 'commit b' && echo 1 || echo 0)"
check "R4: says 20 minutes" "1" \
	"$(printf '%s' "$out" | grep -q '20 minutes' && echo 1 || echo 0)"
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

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
