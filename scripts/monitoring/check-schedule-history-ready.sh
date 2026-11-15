#!/usr/bin/env bash

set -euo pipefail

repo="${REPO:?REPO is required}"
workflow="${1:?workflow file name is required}"
max_age_days="${2:-3}"
retry_delay_seconds="${RETRY_DELAY_SECONDS:-20}"

case "$max_age_days" in
	'' | *[!0-9]*)
		echo "::error::max age must be a whole number of days" >&2
		exit 1
		;;
esac
case "$retry_delay_seconds" in
	'' | *[!0-9]*)
		echo "::error::retry delay must be a whole number of seconds" >&2
		exit 1
		;;
esac

workflow_path=".github/workflows/$workflow"
scheduled_output=""
scheduled_error=""
scheduled_found=false
workflow_missing=false
for attempt in 1 2 3; do
	scheduled_error_file="$(mktemp)"
	if scheduled_output="$(gh run list --repo "$repo" --workflow "$workflow" --event schedule --status success --limit 100 --json createdAt --jq 'map(.createdAt) | max // empty' 2>"$scheduled_error_file")"; then
		rm -f "$scheduled_error_file"
		scheduled_found=true
		break
	fi
	scheduled_error="$(cat "$scheduled_error_file")"
	rm -f "$scheduled_error_file"
	case "$scheduled_error" in
		*"not found on the default branch"*)
			workflow_missing=true
			break
			;;
	esac
	if [ "$attempt" -lt 3 ]; then
		sleep "$retry_delay_seconds"
	fi
done
if [ "$scheduled_found" = false ] && [ "$workflow_missing" = false ]; then
	echo "::error::could not read the scheduled-run history for $workflow" >&2
	printf '%s\n' "$scheduled_error" >&2
	exit 1
fi
if [ "$workflow_missing" = true ] && [ ! -f "$workflow_path" ]; then
	echo ready=true
	exit 0
fi
if [ -n "$scheduled_output" ]; then
	echo ready=true
	exit 0
fi

if [ ! -f "$workflow_path" ]; then
	echo "::error::$workflow_path is not present in this checkout" >&2
	exit 1
fi

added_at="$(git log --diff-filter=A --format=%ct -- "$workflow_path" | head -1)"
if [ -z "$added_at" ]; then
	echo "::error::could not find when $workflow_path entered this branch" >&2
	exit 1
fi

now_epoch="$(date -u +%s)"
age_seconds=$((now_epoch - added_at))
max_age_seconds=$((max_age_days * 86400))
if [ "$age_seconds" -le "$max_age_seconds" ]; then
	echo ready=false
else
	echo ready=true
fi
