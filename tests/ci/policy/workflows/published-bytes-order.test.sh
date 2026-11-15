#!/usr/bin/env bash
#
# The published-bytes watcher downloads whatever URL a manifest declares, and its
# own URL rule only requires a Glyndor release asset. What binds a manifest to the
# product it publishes is scripts/artifacts/check-manifests.sh, so the workflow has
# to run that first and fail before any download. This reads the workflow and
# requires both steps, in that order, with no step that could let the first one
# fail without stopping the job.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

verdict() { # $1 = workflow file
	python3 - "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
where = []  # (job id, index in its job, step)
for jid, job in doc["jobs"].items():
    for i, step in enumerate(job.get("steps", [])):
        if "run" in step:
            where.append((jid, i, step))
def calls(run, name):
    # A line that runs the script, not one that merely names it (an `echo` of it
    # passes a substring test while running nothing).
    return any(line.strip() in (f"bash ./{name}", f"./{name}") for line in run.splitlines())
def find(name):
    hits = [w for w in where if calls(w[2]["run"], name)]
    return hits[0] if len(hits) == 1 else None
first = find("scripts/artifacts/check-manifests.sh")
second = find("scripts/monitoring/check-published-manifests.sh")
if first is None:
    print("the product check is not run exactly once")
elif second is None:
    print("the published-bytes check is not run exactly once")
elif first[0] != second[0]:
    print("the two checks are in different jobs")
elif first[1] > second[1]:
    print("the product check runs after the download check")
elif first[2].get("continue-on-error") or first[2].get("if"):
    print("the product check can be skipped or can fail without stopping the job")
elif doc["jobs"][first[0]].get("if") or doc["jobs"][first[0]].get("continue-on-error"):
    print("the job that holds the product check can be skipped or can fail without failing the workflow")
else:
    print("ok")
PY
}

check "the live workflow runs the product check first and unconditionally" "ok" \
	"$(verdict "$HERE/.github/workflows/published-bytes.yml")"

mkdir -p "$WORK/c"
python3 - "$HERE/.github/workflows/published-bytes.yml" "$WORK/c" <<'PY'
import sys, yaml, copy
doc = yaml.safe_load(open(sys.argv[1]))
def write(name, edit):
    d = copy.deepcopy(doc)
    edit(d)
    yaml.safe_dump(d, open(f"{sys.argv[2]}/{name}.yml", "w"), sort_keys=False)
def steps(d):
    return next(iter(d["jobs"].values()))["steps"]
def drop(d):
    s = steps(d)
    s[:] = [x for x in s if "check-manifests.sh" not in x.get("run", "")]
def swap(d):
    s = steps(d)
    a = next(i for i, x in enumerate(s) if "check-manifests.sh" in x.get("run", ""))
    b = next(i for i, x in enumerate(s) if "check-published-manifests.sh" in x.get("run", ""))
    s[a], s[b] = s[b], s[a]
def soften(d):
    for x in steps(d):
        if "check-manifests.sh" in x.get("run", ""):
            x["continue-on-error"] = True
def echoed(d):
    for x in steps(d):
        if "check-manifests.sh" in x.get("run", "") and "check-published" not in x["run"]:
            x["run"] = "echo " + x["run"]
write("echoed", echoed)
write("dropped", drop)
write("swapped", swap)
def job_soft(d):
    next(iter(d["jobs"].values()))["continue-on-error"] = True
def job_if(d):
    next(iter(d["jobs"].values()))["if"] = "github.event_name == 'schedule'"
def split(d):
    job = next(iter(d["jobs"].values()))
    a = next(i for i, x in enumerate(job["steps"]) if "check-manifests.sh" in x.get("run", ""))
    moved = job["steps"].pop(a)
    d["jobs"]["product"] = {"runs-on": "ubuntu-latest", "steps": [moved]}
write("softened", soften)
write("job-soft", job_soft)
write("job-if", job_if)
write("split", split)
PY
check "a step that only echoes the product check is reported" "the product check is not run exactly once" "$(verdict "$WORK/c/echoed.yml")"
check "without the product check the workflow is reported" "the product check is not run exactly once" "$(verdict "$WORK/c/dropped.yml")"
check "with the checks swapped the workflow is reported" "the product check runs after the download check" "$(verdict "$WORK/c/swapped.yml")"
check "with continue-on-error on the job that holds the product check it is reported" "the job that holds the product check can be skipped or can fail without failing the workflow" "$(verdict "$WORK/c/job-soft.yml")"
check "with a condition on the job that holds the product check it is reported" "the job that holds the product check can be skipped or can fail without failing the workflow" "$(verdict "$WORK/c/job-if.yml")"
check "with the checks in different jobs it is reported" "the two checks are in different jobs" "$(verdict "$WORK/c/split.yml")"
check "with continue-on-error on the product check it is reported" "the product check can be skipped or can fail without stopping the job" "$(verdict "$WORK/c/softened.yml")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
