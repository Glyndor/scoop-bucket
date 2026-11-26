#!/usr/bin/env bash
# The workflow that installs the manifests from the bucket covers every manifest of the bucket, on Windows, and is
# shaped to be read as a test of the published bucket and not of a pull request.
#
#   * the apps of its matrix are the files of bucket/, both ways: a manifest added to the bucket and not to the matrix
#     is an app nobody installs, and one left in the matrix after it left the bucket is a job that fails;
#   * the job runs on a Windows image it names, not on a floating label;
#   * it reads the manifests with ConvertFrom-Json twice, in Windows PowerShell and in PowerShell 7, which parse
#     differently, and installs Scoop from an installer of one commit held to its digest;
#   * it runs on a schedule, on dispatch and on a push that changes bucket/ and nothing else, and on no pull
#     request: it reads the bucket as published, and a pull request has not published anything;
#   * its steps use only actions of GitHub (`actions/`), pinned to a commit, and its checkout keeps the history the
#     manifest before is found in and keeps no credential;
#   * its job has a bound, and a leg that fails does not stop the other.
# Every case is planted first, so a checker that read nothing would not pass them.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import re
import sys
import tempfile
from pathlib import Path

import yaml

root = Path(sys.argv[1])
passed = failed = 0
NAME = "install-from-the-bucket.yml"
PS1 = "./scripts/monitoring/read-manifests.ps1"


def problems(repo):
    found = []
    spec = yaml.safe_load((repo / ".github/workflows" / NAME).read_text()) or {}
    on = spec.get("on", spec.get(True)) or {}
    job = (spec.get("jobs") or {}).get("install") or {}
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    apps = sorted(p.stem for p in (repo / "bucket").glob("*.json"))
    if sorted(matrix.get("app") or []) != apps:
        found.append(f"the matrix installs {sorted(matrix.get('app') or [])} and the bucket has {apps}")
    runner = str(job.get("runs-on"))
    if not runner.startswith("windows-"):
        found.append(f"the job runs on {runner}, which is not a Windows image")
    elif runner.endswith("-latest"):
        found.append(f"the job runs on {runner}, a floating label")
    if (job.get("strategy") or {}).get("fail-fast") is not False:
        found.append("a leg that fails stops the other: fail-fast is not false")
    if not isinstance(job.get("timeout-minutes"), int):
        found.append("the job has no bound of its own")
    steps = job.get("steps") or []
    for shell in ("powershell", "pwsh"):
        if not any(s.get("shell") == shell and s.get("run") == PS1 for s in steps):
            found.append(f"no step reads the manifests with ConvertFrom-Json of {shell}")
    if not any(s.get("shell") == "pwsh" and s.get("run") == "./scripts/monitoring/install-scoop.ps1" for s in steps):
        found.append("no step installs Scoop with the script that holds the installer to its digest")
    env = job.get("env") or {}
    if not re.fullmatch(r"[0-9a-f]{40}", str(env.get("SCOOP_INSTALLER_COMMIT", ""))):
        found.append("the installer of Scoop is not held to a commit")
    if not re.fullmatch(r"[0-9a-f]{64}", str(env.get("SCOOP_INSTALLER_SHA256", ""))):
        found.append("the installer of Scoop is not held to a digest")
    for bad in sorted({"pull_request", "pull_request_target"} & set(on)):
        found.append(f"it runs on {bad}")
    for need in ("schedule", "workflow_dispatch", "push"):
        if need not in on:
            found.append(f"it does not run on {need}")
    push = on.get("push") or {}
    if isinstance(push, dict) and push.get("paths") != ["bucket/**"]:
        found.append(f"its push runs for {push.get('paths')} and not for bucket/** alone")
    for step in steps:
        uses = str(step.get("uses", ""))
        if uses and not re.fullmatch(r"actions/[a-z-]+@[0-9a-f]{40}( # .*)?", uses):
            found.append(f"a step uses {uses}, which is not an action of GitHub pinned to a commit")
        if uses.startswith("actions/checkout"):
            with_ = step.get("with") or {}
            if with_.get("fetch-depth") != 0:
                found.append("the checkout does not keep the history, so the manifest before cannot be found")
            if with_.get("persist-credentials") is not False:
                found.append("the checkout keeps its credential")
    return found


def plant(apps, mutate=lambda spec: None, on=None):
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        (repo / "bucket").mkdir()
        (repo / ".github/workflows").mkdir(parents=True)
        for a in apps:
            (repo / "bucket" / f"{a}.json").write_text("{}\n")
        spec = {
            "on": on or {"schedule": [{"cron": "0 0 * * 2"}], "workflow_dispatch": None, "push": {"branches": ["main"], "paths": ["bucket/**"]}},
            "jobs": {"install": {
                "strategy": {"fail-fast": False, "matrix": {"app": ["podup"]}},
                "runs-on": "windows-2025", "timeout-minutes": 30,
                "env": {"SCOOP_INSTALLER_COMMIT": "1" * 40, "SCOOP_INSTALLER_SHA256": "2" * 64},
                "steps": [{"uses": "actions/checkout@" + "a" * 40 + " # v7", "with": {"persist-credentials": False, "fetch-depth": 0}},
                          {"shell": "powershell", "run": PS1}, {"shell": "pwsh", "run": PS1}, {"shell": "pwsh", "run": "./scripts/monitoring/install-scoop.ps1"}, {"run": "true"}]}},
        }
        mutate(spec)
        (repo / ".github/workflows" / NAME).write_text(yaml.safe_dump(spec, sort_keys=False))
        return problems(repo)


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok    {label}")
        passed += 1
    else:
        print(f"FAIL  {label}\n        expected: {expected}\n        actual:   {actual}")
        failed += 1


def job(spec): return spec["jobs"]["install"]


check("a workflow that installs every manifest on Windows passes", [], plant(["podup"]))
check("a manifest of the bucket that the matrix does not install is refused", ["the matrix installs ['podup'] and the bucket has ['epistle', 'podup']"], plant(["podup", "epistle"]))
check("an app left in the matrix after it left the bucket is refused", ["the matrix installs ['podup'] and the bucket has []"], plant([]))
check("a job that does not run on Windows is refused", ["the job runs on ubuntu-26.04, which is not a Windows image"], plant(["podup"], lambda s: job(s).update({"runs-on": "ubuntu-26.04"})))
check("a Windows job on a floating label is refused", ["the job runs on windows-latest, a floating label"], plant(["podup"], lambda s: job(s).update({"runs-on": "windows-latest"})))
check("a leg that stops the other is refused", ["a leg that fails stops the other: fail-fast is not false"], plant(["podup"], lambda s: job(s)["strategy"].update({"fail-fast": True})))
check("a job with no bound is refused", ["the job has no bound of its own"], plant(["podup"], lambda s: job(s).pop("timeout-minutes")))
check("a workflow that never reads with Windows PowerShell is refused", ["no step reads the manifests with ConvertFrom-Json of powershell"], plant(["podup"], lambda s: job(s)["steps"].pop(1)))
check("a workflow that never reads with PowerShell 7 is refused", ["no step reads the manifests with ConvertFrom-Json of pwsh"], plant(["podup"], lambda s: job(s)["steps"].pop(2)))
check("a workflow that installs Scoop with something else is refused", ["no step installs Scoop with the script that holds the installer to its digest"], plant(["podup"], lambda s: job(s)["steps"].pop(3)))
check("an installer of Scoop that is not held to a commit is refused", ["the installer of Scoop is not held to a commit"], plant(["podup"], lambda s: job(s)["env"].update({"SCOOP_INSTALLER_COMMIT": "master"})))
check("an installer of Scoop that is not held to a digest is refused", ["the installer of Scoop is not held to a digest"], plant(["podup"], lambda s: job(s)["env"].pop("SCOOP_INSTALLER_SHA256")))
check("a run on a pull request is refused", ["it runs on pull_request"], plant(["podup"], on={"schedule": [{"cron": "0 0 * * 2"}], "workflow_dispatch": None, "push": {"paths": ["bucket/**"]}, "pull_request": None}))
check("a run with no schedule is refused", ["it does not run on schedule"], plant(["podup"], on={"workflow_dispatch": None, "push": {"paths": ["bucket/**"]}}))
check("a push for more than the manifests is refused", ["its push runs for ['bucket/**', 'docs/**'] and not for bucket/** alone"], plant(["podup"], on={"schedule": [{"cron": "0 0 * * 2"}], "workflow_dispatch": None, "push": {"paths": ["bucket/**", "docs/**"]}}))
check("a step of a third party is refused", ["a step uses someone/action@" + "b" * 40 + ", which is not an action of GitHub pinned to a commit"], plant(["podup"], lambda s: job(s)["steps"].append({"uses": "someone/action@" + "b" * 40})))
check("an action of GitHub pinned to a tag is refused", ["a step uses actions/cache@v4, which is not an action of GitHub pinned to a commit"], plant(["podup"], lambda s: job(s)["steps"].append({"uses": "actions/cache@v4"})))
check("a checkout without the history is refused", ["the checkout does not keep the history, so the manifest before cannot be found"], plant(["podup"], lambda s: job(s)["steps"][0]["with"].update({"fetch-depth": 1})))
check("a checkout that keeps its credential is refused", ["the checkout keeps its credential"], plant(["podup"], lambda s: job(s)["steps"][0]["with"].update({"persist-credentials": True})))
check("the live workflow covers the bucket", [], problems(root))
print(f"\n{passed} passed, {failed} failed")
print(f"DONE install-covers-the-bucket.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
