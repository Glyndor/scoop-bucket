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
steps = [s for j in doc["jobs"].values() for s in j.get("steps", [])]
runs = [(i, s) for i, s in enumerate(steps) if "run" in s]
def find(name):
    hits = [(i, s) for i, s in runs if name in s["run"]]
    return hits[0] if len(hits) == 1 else None
first = find("scripts/artifacts/check-manifests.sh")
second = find("scripts/monitoring/check-published-manifests.sh")
if first is None:
    print("the product check is not run exactly once")
elif second is None:
    print("the published-bytes check is not run exactly once")
elif first[0] > second[0]:
    print("the product check runs after the download check")
elif first[1].get("continue-on-error") or first[1].get("if"):
    print("the product check can be skipped or can fail without stopping the job")
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
write("dropped", drop)
write("swapped", swap)
write("softened", soften)
PY
check "without the product check the workflow is reported" "the product check is not run exactly once" "$(verdict "$WORK/c/dropped.yml")"
check "with the checks swapped the workflow is reported" "the product check runs after the download check" "$(verdict "$WORK/c/swapped.yml")"
check "with continue-on-error on the product check it is reported" "the product check can be skipped or can fail without stopping the job" "$(verdict "$WORK/c/softened.yml")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
