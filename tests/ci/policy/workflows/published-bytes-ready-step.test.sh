#!/usr/bin/env bash
#
# The step of freshness.yml that says whether the published-bytes watcher has a
# history to measure decides whether that watcher runs at all: a skipped job
# reports success. A pull request must not be the one that writes its answer, so
# in a pull request the step runs the copy of the script in the base commit, and
# its output is exactly `ready=true` or `ready=false`, whatever the script
# printed, with `ready=true` (the watcher runs) for anything else.
#
# The shell of the step is taken out of the workflow as it ships and run in a
# temporary git repository whose HEAD is a merge commit, as the checkout of a
# pull request is. The script is a stand-in that prints what each case says, so
# what is measured is which copy runs and what reaches the outputs file.
#
# Requires: bash, git, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
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

# shellcheck disable=SC1091 # the fixture reads a step out of a workflow
. "$HERE/tests/fixtures/ci/step-script.sh"
STEP="$(step_script "$HERE/.github/workflows/freshness.yml" 'Check whether published-bytes has scheduled-run history')"
check "the step is found in the workflow" "1" "$([ -n "$STEP" ] && echo 1 || echo 0)"

SCRIPT_PATH=scripts/monitoring/check-schedule-history-ready.sh
R="$WORK/repo"
gitr() { git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
# The stand-in script prints the text it is given, so a case can print two lines
# or anything else. $1 is a printf format.
stand_in() { # $1=printf argument written into the script, "" for no script
	if [ -n "$1" ]; then
		mkdir -p "$R/scripts/monitoring"
		printf '#!/usr/bin/env bash\nprintf %s\n' "$1" > "$R/$SCRIPT_PATH"
	else
		rm -f "$R/$SCRIPT_PATH"
	fi
}
# A repository whose main prints $1 and whose pull request branch prints $2 ("" for
# no script on either side), merged with a merge commit, so HEAD^1 is main.
pull_request() { # $1=what the base prints $2=what the pull request prints
	rm -rf "$R"; mkdir -p "$R"; gitr init -q -b main
	stand_in "$1"; : > "$R/file"; gitr add -A; gitr commit -qm base
	gitr checkout -q -b pr
	stand_in "$2"; echo change >> "$R/file"; gitr add -A; gitr commit -qm change
	gitr checkout -q main
	gitr merge -q --no-ff pr -m merge
}
# Run the step in the repository with the event named; prints what it wrote to the
# outputs file, with newlines shown as `|`, and sets rc.
run_step() { # $1=event
	rm -f "$WORK/out"; : > "$WORK/out"
	( cd "$R" && EVENT="$1" RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/out" GH_TOKEN=x REPO=x \
		bash -c "$STEP" > "$WORK/log" 2>&1 )
	echo $? > "$WORK/rc"
	tr '\n' '|' < "$WORK/out"
}
status() { cat "$WORK/rc"; }

pull_request "'ready=false\n'" "'ready=true\n'"
check "a pull request that makes the script print ready=true does not change the answer" "ready=false|" "$(run_step pull_request)"
check "and the step succeeds" "0" "$(status)"
pull_request "'ready=true\n'" "'ready=false\n'"
check "nor one that makes it print ready=false" "ready=true|" "$(run_step pull_request)"
pull_request "'ready=false\n'" "'ready=false\n'"
check "the base's own answer is what is written" "ready=false|" "$(run_step pull_request)"

pull_request "'ready=false\nready=true\n'" "'ready=false\n'"
check "an output with two lines is ready=true" "ready=true|" "$(run_step pull_request)"
pull_request "'ready=false\nGITHUB_ENV=x\n'" "'ready=false\n'"
check "an output that would write another key is ready=true, and writes nothing else" "ready=true|" "$(run_step pull_request)"
pull_request "'ready=maybe\n'" "'ready=false\n'"
check "an output that is neither value is ready=true" "ready=true|" "$(run_step pull_request)"
pull_request "''" "'ready=false\n'"
check "an empty output is ready=true" "ready=true|" "$(run_step pull_request)"
pull_request "" "'ready=false\n'"
check "a base without the script is ready=true, the script of the pull request not run" "ready=true|" "$(run_step pull_request)"
check "and the step succeeds" "0" "$(status)"
pull_request "'ready=false\n'" ""
check "a pull request that deletes the script still gets the base's answer" "ready=false|" "$(run_step pull_request)"

# The script of the base failing fails the step, as it always did: the job is red
# and the watcher is not skipped by a green one.
pull_request "'ready=false\n'; exit 3" "'ready=false\n'"
run_step pull_request > /dev/null
check "a base script that fails fails the step" "1" "$([ "$(status)" -ne 0 ] && echo 1 || echo 0)"

# Outside a pull request there is no other commit to ask: the checkout's own copy runs.
for event in push schedule workflow_dispatch; do
	pull_request "'ready=true\n'" "'ready=false\n'"
	gitr checkout -q pr
	check "on $event the script of the checkout runs" "ready=false|" "$(run_step "$event")"
	gitr checkout -q main
done
gitr checkout -q pr
stand_in "'ready=maybe\n'"
check "on a push an answer that is neither value is ready=true as well" "ready=true|" "$(run_step push)"
rm -f "$R/$SCRIPT_PATH"
got="$(run_step push)"
check "on a push with no script the step fails or says ready=true, it never skips the watcher" "1" "$([ "$got" = "ready=true|" ] || [ "$(status)" -ne 0 ] && echo 1 || echo 0)"

# The temporary copy is not left behind.
pull_request "'ready=false\n'" "'ready=false\n'"
run_step pull_request > /dev/null
check "no temporary copy of the script is left in RUNNER_TEMP" "0" "$(find "$WORK" -maxdepth 1 -name 'history-ready.*' | wc -l)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
