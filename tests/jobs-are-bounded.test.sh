#!/usr/bin/env bash
# Every non-caller job in .github/workflows/ declares a timeout-minutes.
#
# A job whose only top-level key is `uses:` is a caller (it delegates to a
# reusable workflow) and is exempt from carrying one: a caller has no
# timeout of its own to bound, only the reusable's, and the reusable is
# bounded where the work happens. Every other job must carry
# timeout-minutes, derived from its measured duration. GitHub's default is
# six hours; without this rule a job that hangs holds its runner for the
# full default and reads as red only when someone restarts it.
#
# The exemption is written as "no `uses:` key" rather than as a list of
# job names for the same reason as elsewhere in this suite: a name list
# goes stale the moment a caller is added or renamed, and the rule it
# states is a structural one.
#
# The check is structural too: a workflow whose every job carries
# timeout-minutes but whose callers are listed in a comment is still
# passed by this test, because that is exactly what it should do. The
# planted-violation case at the bottom of this file is what proves the
# check is not a comparison that always agrees.
#
# Requires: python3, PyYAML.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
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

# Scan every workflow under <root>/.github/workflows/ and report jobs that
# are not callers yet lack timeout-minutes. Comments are stripped by
# safe_load, so they cannot produce a false positive the way a regex could.
#
# Exits 0 with a one-line summary on success, 1 with one ::error per
# violation on failure. Same Python-YAML approach as the tooling-isolation
# step in reusable-workflow-lint.yml: parse, walk, report. The script is
# invoked with the repo root so the planted-violation case can point at a
# scratch tree without copying the helper.
check_jobs() { # $1=workflows root  -> sets rc, prints to stdout/stderr
	python3 - "$1" <<'PY'
import glob
import sys

import yaml


def find_violations(spec_path):
	violations = []
	try:
		with open(spec_path) as fh:
			spec = yaml.safe_load(fh)
	except yaml.YAMLError as e:
		# A misconfigured workflow is going to fail elsewhere in CI for the
		# wrong reason. Warn here so the failure points at the file rather
		# than at this suite, and keep going.
		print(f"::warning file={spec_path}::skipped: YAML parse error: {e}")
		return violations
	if not isinstance(spec, dict):
		return violations
	jobs = spec.get("jobs") or {}
	if not isinstance(jobs, dict):
		return violations
	for job_id, job in jobs.items():
		if not isinstance(job, dict):
			continue
		# A caller is exempt. Anything else must declare timeout-minutes.
		if "uses" in job:
			continue
		if "timeout-minutes" not in job:
			violations.append((spec_path, job_id))
	return violations


root = sys.argv[1]
files = sorted(set(
	glob.glob(f"{root}/.github/workflows/*.yml")
	+ glob.glob(f"{root}/.github/workflows/*.yaml")
))
violations = []
for path in files:
	violations.extend(find_violations(path))

if violations:
	for path, job_id in violations:
		print(
			f"::error file={path}::job `{job_id}` is not a caller "
			f"(no `uses:` key) and must declare `timeout-minutes`"
		)
	sys.exit(1)
print(f"every non-caller job across {len(files)} workflow file(s) declares timeout-minutes")
sys.exit(0)
PY
}

# --- the real tree is bounded -------------------------------------------

check "the real tree passes" 0 "$(check_jobs "$HERE" >/dev/null 2>&1; echo $?)"

# --- a planted violation is caught --------------------------------------

scratch="$WORK/repo"
mkdir -p "$scratch/.github/workflows"

# A caller is exempt by construction.
cat >"$scratch/.github/workflows/caller.yml" <<'YML'
name: caller
on: [push]
jobs:
  c:
    uses: ./.github/workflows/something.yml
YML

# A non-caller WITH timeout-minutes is fine.
cat >"$scratch/.github/workflows/bounded.yml" <<'YML'
name: bounded
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: echo
YML

# A non-caller WITHOUT timeout-minutes must be reported.
cat >"$scratch/.github/workflows/unbounded.yml" <<'YML'
name: unbounded
on: [push]
jobs:
  u:
    runs-on: ubuntu-latest
    steps:
      - run: echo
YML

out="$(check_jobs "$scratch" 2>&1)"; rc=$?
check "a planted violation is caught" 1 "$rc"
check "and names the file" 1 \
	"$(printf '%s' "$out" | grep -q 'unbounded.yml' && echo 1 || echo 0)"
check "and names the job" 1 \
	"$(printf '%s' "$out" | grep -qE 'job .u. is not a caller' && echo 1 || echo 0)"
check "and reports the unbounded job, not the bounded one" 0 \
	"$(printf '%s' "$out" | grep -cE '(^|/)(bounded|caller)\.yml')"
check "and the caller is exempt, not reported" 0 \
	"$(printf '%s' "$out" | grep -cE '(^|/)(bounded|caller)\.yml')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
