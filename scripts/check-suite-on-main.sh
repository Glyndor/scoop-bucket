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
# reading the newest COMPLETED run of the suite workflow on `main` and
# failing when its conclusion is anything other than success. A run
# still in progress is filtered out at the API layer, so it cannot be
# misread as either pass or fail.
#
# Empty history is reported, not passed. A workflow whose first run on
# main is still queued is not a green signal; "we cannot tell" reads as
# red until something is on record to tell. That is the same shape the
# schedule-freshness gate has used since its first version.
#
# Requires: GH_TOKEN (the job-scoped token), REPO (owner/name), and
# WORKFLOW (the workflow's file name, e.g. tests.yml) in the
# environment. The caller must grant `actions: read` alongside
# `contents: read`: a called workflow cannot elevate beyond the
# permissions of the workflow that calls it, and reading run history
# through the API needs that scope.
#
# Usage: check-suite-on-main.sh   (no arguments; reads the environment)

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required (owner/repo)}"
: "${WORKFLOW:?WORKFLOW is required (workflow file name, e.g. tests.yml)}"

# Newest completed run of <WORKFLOW> on main. status=completed excludes
# queued and in-progress runs; branch=main excludes pull-request and
# tag runs. per_page=1 because we only need the head of the list, and
# the script must read one run, not page through history.
#
# `sort_by(.created_at) | reverse` is defensive: GitHub's default
# ordering is by created_at desc, but the gate should not silently
# assume that stays true across API changes. We pull id, conclusion,
# created_at, html_url and event in one query so the failure message
# names the run it saw, and the URL is one click from the gate log.
result=$(gh api \
	"repos/${REPO}/actions/workflows/${WORKFLOW}/runs?branch=main&status=completed&per_page=1" \
	--jq 'if (.workflow_runs | length) == 0 then "EMPTY"
	      else (.workflow_runs | sort_by(.created_at) | reverse | .[0] |
	            [.id, .conclusion, .created_at, .html_url, .event]) | @tsv
	      end')

if [ "$result" = "EMPTY" ]; then
	echo "::error::No completed run on record for ${WORKFLOW} on main."
	echo "A run still in progress is not a pass -- 'we cannot tell' is red" >&2
	echo "until something is on record to tell. Wait for the next scheduled" >&2
	echo "fire, or trigger ${WORKFLOW} by hand to produce a record." >&2
	exit 1
fi

IFS=$'\t' read -r id conclusion created url event <<< "$result"
echo "Newest completed run of ${WORKFLOW} on main: #${id} (event=${event}, conclusion=${conclusion}, ${created})"
echo "  ${url}"

if [ "$conclusion" != "success" ]; then
	echo "::error::${WORKFLOW} is red on main: newest completed run concluded '${conclusion}'."
	echo "Open ${url} for the failure, fix the suite, and push to record a green run." >&2
	exit 1
fi

echo "Newest completed run on main concluded success."
