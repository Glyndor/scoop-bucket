#!/usr/bin/env bash
#
# The updater app's private key lives in exactly one job of update.yml, and
# that job installs nothing and commits only the bytes the render job recorded.
#
# The render job installs a package from the distribution's archive and runs
# the renderer over what a product published. When that was the same job that
# then minted the app's token and committed whatever was in the workspace, that
# code could rewrite a manifest, or the scripts the commit step runs, before
# the step that used the token. Three properties keep the split meaningful, and
# each has its own assertion here:
#
#   (a) the only job that references a secret is `commit`, it installs nothing
#       and uses only first-party actions, and both jobs hold `contents: read`
#       and nothing more;
#   (b) `commit` needs `render`, with no condition that would run it after the
#       render failed;
#   (c) before it mints the token, `commit` checks the files against the
#       digests the render job put in its outputs, not against a file in the
#       artifact, and holds them to the roster again.
#
# The structure is read with PyYAML and every rule is first shown reporting a
# planted break in a copy of the live workflow. What the check step does when
# it runs, and how the outputs cross from one job to the other, is in
# update-digest-handoff.test.sh.
#
# Requires: python3 with PyYAML.
# The plants carry literal `${{ }}` and `$VAR` into Python; single quotes are the point.
# shellcheck disable=SC2016
HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/publication" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/update-fixture.sh"
pass=0
fail=0

# Prints one line per broken rule, nothing when the workflow keeps all three.
rules() { # $1 = workflow file
	python3 -I - "$1" <<'PY'
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc.get("jobs") or {}
SECRET = re.compile(r"(?<!\w)secrets(?:\.|\[)")
INSTALL = re.compile(r"\b(apt-get|apt|pip3?|gem|npm|cargo|go)\s+(install|i)\b|\bsudo\b")
ALLOWED_USES = ("actions/checkout@", "actions/download-artifact@", "actions/create-github-app-token@")


def runs(step):
    return [l for l in str(step.get("run", "")).splitlines() if l.strip() and not l.lstrip().startswith("#")]


def text(node):
    return yaml.safe_dump(node)


# (a) who holds the key, and what that job runs
holders = sorted(j for j, job in jobs.items() if SECRET.search(text(job)))
if holders != ["commit"]:
    print(f"(a) the jobs referencing a secret are {holders}, not ['commit']")
commit = jobs.get("commit") or {}
for step in commit.get("steps") or []:
    for line in runs(step):
        if INSTALL.search(line):
            print(f"(a) the commit job runs `{line.strip()}`")
    uses = step.get("uses")
    if uses and not uses.startswith(ALLOWED_USES):
        print(f"(a) the commit job uses {uses}")
for name in ("render", "commit"):
    if (jobs.get(name) or {}).get("permissions") != {"contents": "read"}:
        print(f"(a) the {name} job does not hold contents: read alone")

# (b) the commit job runs only after the render succeeded
needs = commit.get("needs") or []
needs = [needs] if isinstance(needs, str) else needs
if "render" not in needs:
    print("(b) the commit job does not need render")
if "if" in commit:
    print(f"(b) the commit job carries a condition: {commit['if']}")
for name in ("render", "commit"):
    job = jobs.get(name) or {}
    if job.get("continue-on-error") or any(s.get("continue-on-error") for s in job.get("steps") or []):
        print(f"(b) the {name} job lets a failure through")

# (c) the digest is checked, from the render job's outputs, before the key is used
steps = commit.get("steps") or []
def index(pred):
    return next((n for n, s in enumerate(steps) if pred(s)), None)
place = index(lambda s: any(re.match(r"bash \./scripts/artifacts/manifest-digests\.sh place ", l.strip()) for l in runs(s)))
roster = index(lambda s: any(l.strip() == "./scripts/artifacts/check-manifests.sh" or l.strip() == "bash ./scripts/artifacts/check-manifests.sh" for l in runs(s)))
mint = index(lambda s: str(s.get("uses", "")).startswith("actions/create-github-app-token@"))
publish = index(lambda s: "createCommitOnBranch" in str(s.get("run", "")))
if place is None or publish is None or not place < publish:
    print("(c) no step checks the digests before the commit step")
elif mint is None or not place < mint:
    print("(c) the digests are checked after the key is used")
if roster is None or publish is None or not roster < publish:
    print("(c) the commit job does not hold the files to the roster before the commit step")
elif mint is None or not roster < mint:
    print("(c) the roster check runs after the key is used")
if place is not None:
    env = steps[place].get("env") or {}
    if env.get("RENDERED_DIGESTS") != "${{ needs.render.outputs.digests }}":
        print("(c) the digests do not come from the render job's outputs")
    if env.get("RENDERED_HEAD") != "${{ needs.render.outputs.head }}":
        print("(c) the head does not come from the render job's outputs")
if any("manifests.sha256" in l for s in steps for l in runs(s)):
    print("(c) the commit job reads the manifest the artifact carries")
render = jobs.get("render") or {}
recorder = next((s for s in render.get("steps") or [] if s.get("id") == "digests"), {})
outputs = render.get("outputs") or {}
if outputs.get("digests") != "${{ steps.digests.outputs.digests }}" \
        or not any(l.strip().startswith("bash ./scripts/artifacts/manifest-digests.sh list ") for l in runs(recorder)):
    print("(c) the render job does not record the digests in its outputs")
if outputs.get("head") != "${{ steps.digests.outputs.head }}":
    print("(c) the render job does not record its head in its outputs")
PY
}

check "the live workflow keeps all three rules" "" "$(rules "$WORKFLOW")"

# Each plant edits a copy of the live workflow, must change it, and must be
# reported under the rule it breaks.
plant() { # $1 = name, $2 = expected text in the report, $3 = python edit of doc
	local copy="$WORK/plant-$1.yml"
	python3 -I - "$WORKFLOW" "$copy" "$3" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc["jobs"]
steps = jobs["commit"]["steps"]
def named(job, prefix):
    return next(s for s in jobs[job]["steps"] if str(s.get("name", "")).startswith(prefix))
exec(sys.argv[3])
open(sys.argv[2], "w").write(yaml.safe_dump(doc, sort_keys=False))
PY
	if [ "$(python3 -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])) == yaml.safe_load(open(sys.argv[2])))' "$WORKFLOW" "$copy")" = True ]; then
		check "plant $1 changed the workflow" "changed" "unchanged"
		return
	fi
	check "plant $1 is reported" "1" "$(rules "$copy" | grep -cF -- "$2" | awk '{print ($1 > 0)}')"
}

plant install-in-commit "(a) the commit job runs" \
	'c = named("commit", "Check the rendered"); c["run"] += "sudo apt-get install -y python3-cryptography\n"'
plant pip-in-commit "(a) the commit job runs" \
	'c = named("commit", "Check the rendered"); c["run"] += "pip install requests\n"'
plant mint-in-render "(a) the jobs referencing a secret are ['commit', 'render']" \
	'jobs["render"]["steps"].append(named("commit", "Mint a token"))'
plant third-party-action "(a) the commit job uses" \
	'steps.insert(0, {"uses": "someone/action@0000000000000000000000000000000000000000"})'
plant write-permission "(a) the render job does not hold contents: read alone" \
	'jobs["render"]["permissions"] = {"contents": "write"}'
plant commit-write-permission "(a) the commit job does not hold contents: read alone" \
	'jobs["commit"]["permissions"] = {"contents": "read", "actions": "write"}'
plant unneeded-render "(b) the commit job does not need render" \
	'jobs["commit"]["needs"] = []'
plant always "(b) the commit job carries a condition" \
	'jobs["commit"]["if"] = "${{ always() }}"'
plant ignored-validation "(b) the render job lets a failure through" \
	'named("render", "Validate the re-rendered")["continue-on-error"] = True'
plant ignored-check "(b) the commit job lets a failure through" \
	'named("commit", "Check the rendered")["continue-on-error"] = True'
plant check-after-commit "(c) no step checks the digests before the commit step" \
	'c = named("commit", "Check the rendered"); steps.remove(c); steps.append(c)'
plant check-after-mint "(c) the digests are checked after the key is used" \
	'c = named("commit", "Check the rendered"); steps.remove(c); steps.insert(steps.index(named("commit", "Commit the update")), c)'
plant no-place "(c) no step checks the digests before the commit step" \
	'c = named("commit", "Check the rendered"); c["run"] = c["run"].replace("bash ./scripts/artifacts/manifest-digests.sh place", ": ./scripts/artifacts/manifest-digests.sh place")'
plant no-roster "(c) the commit job does not hold the files to the roster" \
	'c = named("commit", "Check the rendered"); c["run"] = c["run"].replace("./scripts/artifacts/check-manifests.sh", ":")'
plant digests-from-another-output "(c) the digests do not come from the render job's outputs" \
	'named("commit", "Check the rendered")["env"]["RENDERED_DIGESTS"] = "${{ needs.render.outputs.changed }}"'
plant head-from-another-output "(c) the head does not come from the render job's outputs" \
	'named("commit", "Check the rendered")["env"]["RENDERED_HEAD"] = "${{ needs.render.outputs.changed }}"'
plant digests-from-artifact "(c) the commit job reads the manifest the artifact carries" \
	'c = named("commit", "Check the rendered"); c["run"] = c["run"].replace(". \"$expected\"\n", ". \"$RUNNER_TEMP/rendered/manifests.sha256\"\n")'
plant no-record "(c) the render job does not record the digests" \
	'del jobs["render"]["outputs"]["digests"]'
plant no-head-record "(c) the render job does not record its head" \
	'del jobs["render"]["outputs"]["head"]'

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
