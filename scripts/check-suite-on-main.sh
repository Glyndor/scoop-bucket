#!/usr/bin/env bash
#
# Fail when the newest completed run of the suite workflow on `main`
# concluded with anything other than `success`.
#
# The schedule-freshness gate already covers "the workflow stopped
# firing", because it counts successful scheduled runs. What it does not
# cover is "the workflow fired and the run was red": that run never
# enters the schedule-freshness history at all, because its conclusion
# is not success. So when a manifest update breaks the suite and the
# bot commits the result straight to `main`, nothing says a word until
# somebody goes looking.
#
# This gate turns the failure into a red check on ordinary work by
# reading the run the workflow must report on. A run still in progress
# is filtered out at the API layer on the schedule and pull_request
# paths, so it cannot be misread as either pass or fail.
#
# On 2026-09-19 this script did the wrong thing on push. It ran at the
# same moment as the `tests.yml` run for the commit being pushed and
# asked for the newest COMPLETED `tests.yml` run on `main`; on a push
# that is the previous commit's run. After `main` had been red, the
# push that fixed it got a red cross from this gate while its own
# `tests.yml` was green:
#
#   tests.yml                15:22:53 - 15:23:26   success
#   suite is green on main   15:22:57 - 15:23:03   failure   (read the run from 01:26Z)
#
# Two more defects of the same shape: with `per_page=1` the script
# trusted the first item of a filtered page, which is not always the
# newest run; and a `cancelled` run was reported as red, although it
# only meant a newer push superseded it.
#
# The script now branches on GITHUB_EVENT_NAME:
#
#   * push. The verdict is the `tests.yml` run whose head_sha is
#     GITHUB_SHA. The page is requested with `head_sha=GITHUB_SHA` as
#     a URL filter so 30 or more newer runs on the branch (re-runs of
#     older commits) cannot push THIS commit's run off the page, and
#     without `status=completed` so an in-progress run for this
#     commit is visible; we sort by created_at desc in the script and
#     pick the head whose head_sha matches, with the jq select as a
#     second guard. If the run is missing or still in progress, sleep
#     15 s and look again, for at most 32 attempts (8 minutes, inside
#     the job's 10-minute timeout; the suite finishes in well under
#     that: apt about 2 minutes, homebrew-tap 1 to 4, scoop-bucket 33 s,
#     measured 2026-09-19). After the last attempt the script fails
#     with one line naming the commit, rather than reading another
#     commit's run.
#
#   * schedule, pull_request. The newest completed run on `main`, from
#     a page of `per_page=30` sorted by created_at desc in the script
#     so it does not trust the order of the page. `cancelled` runs
#     are passed over and the count is reported, because a cancelled
#     run only means a newer push superseded it (pull_request) or an
#     in-flight rerun happened (schedule). A page where every
#     completed run was cancelled fails with a no-verdict message,
#     distinct from the empty-history failure below because the
#     history is non-empty: it just says nothing.
#
# Empty history on the schedule/pull_request path is reported, not
# passed. A workflow whose first run on main is still queued is not a
# green signal; "we cannot tell" reads as red until something is on
# record to tell. That is the same shape the schedule-freshness gate
# has used since its first version.
#
# Requires: GH_TOKEN (the job-scoped token), REPO (owner/name), and
# WORKFLOW (the workflow's file name, e.g. tests.yml) in the
# environment, plus GITHUB_SHA and the automatic GITHUB_EVENT_NAME on
# push. The caller must grant `actions: read` alongside
# `contents: read`: a called workflow cannot elevate beyond the
# permissions of the workflow that calls it, and reading run history
# through the API needs that scope.
#
# Usage: check-suite-on-main.sh   (no arguments; reads the environment)

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required (owner/repo)}"
: "${WORKFLOW:?WORKFLOW is required (workflow file name, e.g. tests.yml)}"

EVENT_NAME="${GITHUB_EVENT_NAME:-}"

if [ "$EVENT_NAME" = "push" ]; then
	: "${GITHUB_SHA:?GITHUB_SHA is required on push events}"
	PUSH_SHA="$GITHUB_SHA"
	base="repos/${REPO}/actions/workflows/${WORKFLOW}/runs?branch=main&head_sha=${PUSH_SHA}&per_page=30"

	# Push path: the verdict is the run for THIS commit, looked up by
	# head_sha. The page is requested with head_sha as a URL filter so
	# the listing cannot be filled by 30 or more newer runs on the
	# branch (re-runs of older commits), and without `status=completed`
	# so an in-progress run for this commit is visible -- that is the
	# signal to wait, not the signal that nothing happened. The jq
	# select on head_sha stays as a second guard so a one-item stale
	# page cannot masquerade as the answer either.
	#
	# Suite runs measured 2026-09-19: apt about 2 minutes,
	# homebrew-tap 1 to 4, scoop-bucket 33 seconds. 32 attempts at
	# 15 seconds gives 8 minutes of waiting, well inside the job's
	# 10-minute timeout, with the 31 sleeps between attempts and
	# none after the last attempt.
	max_attempts=32
	sleep_seconds=15

	# GITHUB_SHA is a 40-character hex string and contains no
	# jq-special characters, so interpolating it into the filter is
	# safe.
	filter=$(cat <<EOF
.workflow_runs
| sort_by(.created_at) | reverse
| map(select(.head_sha == "$PUSH_SHA"))
| .[0]
| if . == null then "EMPTY"
  else [.id, .status, .conclusion, .created_at, .html_url, .event, .head_sha] | @tsv
  end
EOF
	)

	for attempt in $(seq 1 "$max_attempts"); do
		result=$(gh api "$base" --jq "$filter")

		if [ "$result" = "EMPTY" ]; then
			if [ "$attempt" -lt "$max_attempts" ]; then
				sleep "$sleep_seconds"
			fi
			continue
		fi

		IFS=$'\t' read -r id status conclusion created url event head_sha <<< "$result"

		if [ "$status" = "completed" ]; then
			echo "${WORKFLOW} run on main for ${head_sha}: #${id} (event=${event}, conclusion=${conclusion}, ${created})"
			echo "  ${url}"

			if [ "$conclusion" = "success" ]; then
				echo "${WORKFLOW} run for ${head_sha} concluded success."
				exit 0
			fi

			# Anything else, failure, cancelled, timed_out,
			# neutral, skipped, is red. A cancelled run for
			# THIS commit means a newer push superseded it;
			# that newer push gets its own check, but for THIS
			# push the verdict on record is "no", so red it
			# is. The schedule/pull_request path treats
			# cancelled as a superseded-run signal and passes
			# it over.
			echo "::error::${WORKFLOW} is red on main: run for ${head_sha} concluded '${conclusion}'."
			echo "Open ${url} for the failure, fix the suite, and push to record a green run." >&2
			exit 1
		fi

		# Run exists but is queued or in_progress. Wait and ask
		# again; the next attempt's sleep is what brings the
		# suite time budget into reach.
		if [ "$attempt" -lt "$max_attempts" ]; then
			sleep "$sleep_seconds"
		fi
	done

	# 32 attempts saw no completed run for this commit. Either the
	# suite is still running past 8 minutes or it never started;
	# either way this script will not pretend another commit's run
	# answers for it.
	echo "::error::No ${WORKFLOW} run for commit ${PUSH_SHA} finished within 8 minutes; not reading another commit's run."
	exit 1
fi

# Schedule and pull_request path. Newest completed run on `main`,
# never trusting the order of the page. per_page=30 so a flurry of
# runs from one push does not push the next push's verdict out of
# view; the sort by created_at desc happens here so a one-item stale
# page cannot masquerade as the answer either.
#
# `cancelled` is passed over, a newer push superseded it on
# pull_request, an in-flight rerun on schedule, and the count is
# reported in the output so a reader of the log can tell why no run
# is named. A page where every completed run was cancelled fails with
# a no-verdict message, distinct from the empty-history failure below
# because the history is non-empty: it just says nothing.

base="repos/${REPO}/actions/workflows/${WORKFLOW}/runs?branch=main&status=completed&per_page=30"

# Output shape: the head of the kept runs as TSV (id, conclusion,
# created_at, html_url, event) or the literal "EMPTY", followed by a
# tab and the count of cancelled runs skipped. The split happens in
# shell with ${var%tab*} / ${var##*tab} so this stays one API call.
# shellcheck disable=SC2016 # $kept and $skipped are jq variables, not bash
filter='
.workflow_runs
| sort_by(.created_at) | reverse
| map(select(.conclusion != "cancelled")) as $kept
| (length - ($kept | length)) as $skipped
| if ($kept | length) == 0
  then "EMPTY\t\($skipped)"
  else ($kept | .[0] | [.id, .conclusion, .created_at, .html_url, .event] | @tsv) + "\t\($skipped)"
  end'

result=$(gh api "$base" --jq "$filter")

skipped="${result##*$'\t'}"
body="${result%$'\t'*}"

if [ "$body" = "EMPTY" ]; then
	if [ "${skipped:-0}" -gt 0 ] 2>/dev/null; then
		echo "::error::No verdict on ${WORKFLOW} on main: every completed run was cancelled (${skipped} passed over)."
		echo "A newer push (pull_request) or an in-flight rerun (schedule) is the" >&2
		echo "only reason a completed run is cancelled; nothing completed so this" >&2
		echo "gate cannot say the suite is green. Wait for the next scheduled fire" >&2
		echo "or trigger ${WORKFLOW} by hand to produce a record." >&2
		exit 1
	fi
	echo "::error::No completed run on record for ${WORKFLOW} on main."
	echo "A run still in progress is not a pass -- 'we cannot tell' is red" >&2
	echo "until something is on record to tell. Wait for the next scheduled" >&2
	echo "fire, or trigger ${WORKFLOW} by hand to produce a record." >&2
	exit 1
fi

IFS=$'\t' read -r id conclusion created url event <<< "$body"
echo "Newest completed run of ${WORKFLOW} on main: #${id} (event=${event}, conclusion=${conclusion}, ${created})"
if [ "${skipped:-0}" -gt 0 ] 2>/dev/null; then
	echo "  (${skipped} cancelled run(s) passed over)"
fi
echo "  ${url}"

if [ "$conclusion" != "success" ]; then
	echo "::error::${WORKFLOW} is red on main: newest completed run concluded '${conclusion}'."
	echo "Open ${url} for the failure, fix the suite, and push to record a green run." >&2
	exit 1
fi

echo "Newest completed run on main concluded success."