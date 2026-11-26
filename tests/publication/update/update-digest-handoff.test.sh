#!/usr/bin/env bash
#
# How the render job hands its bytes to the commit job in update.yml, run as the
# workflow ships it.
#
# The commit job is the only one holding the updater app's key, so what it
# commits has to be what the render job produced and nothing a later step could
# have swapped in. Two steps carry that, one in each job, and this suite
# extracts both from the workflow and executes them:
#
#   - "Record the digest of every rendered manifest" (render job) writes the
#     digests and the head it rendered from to its outputs, one line each;
#   - "Check the rendered bytes against the render job's digests" (commit job)
#     refuses the artifact unless it is exactly what those outputs describe,
#     and then holds the placed files to the roster again.
#
# The `if:` conditions and the output mapping between the jobs belong to the
# Actions engine. The last part of this suite plays the engine for the
# commit job: it takes the outputs a real run of the render steps produced,
# maps them through the render job's `outputs:`, evaluates the `if:` of every
# step of the commit job, and runs the failure step when the plan says so.
#
# Requires: python3 with PyYAML, git, jq.
HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/publication" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/update-fixture.sh"
pass=0
fail=0

RECORD="$WORK/record.sh"
VERIFY="$WORK/verify.sh"
FAILSTEP="$WORK/fail.sh"
step_script "Record the digest of every rendered manifest" > "$RECORD"
step_script "Check the rendered bytes against" > "$VERIFY"
step_script "Fail if any product was skipped" > "$FAILSTEP"
check "the record step was extracted from the workflow" "1" "$(grep -c 'manifest-digests.sh list' "$RECORD")"
check "the check step was extracted from the workflow" "1" "$(grep -c 'manifest-digests.sh place' "$VERIFY")"
check "the check step holds the placed files to the roster" "1" "$(grep -c 'check-manifests.sh' "$VERIFY")"
check "the failure step was extracted from the workflow" "1" "$(grep -c 'skipped at least one product' "$FAILSTEP")"

# The render job: render in one sandbox, then record.
render_and_record() { # $1 = generator exit code, $2 = mode
	sandbox "$WORK/r" "$1" "$2"
	rm -rf "$WORK/r-tmp"; mkdir -p "$WORK/r-tmp"
	rc=0; run_step "$RENDER" "$WORK/r" || rc=$?
	cp "$WORK/gh-output" "$WORK/render.out"
	: > "$WORK/gh-output"
	# The record step is gated on the change, as it is in the workflow.
	if grep -qx 'changed=1' "$WORK/render.out"; then
		( cd "$WORK/r" && RUNNER_TEMP="$WORK/r-tmp" GITHUB_OUTPUT="$WORK/gh-output" bash "$RECORD" ) > "$WORK/out" 2>&1 || rc=$?
	fi
	cp "$WORK/gh-output" "$WORK/digests.out"
}

render_and_record 0 valid
check "the record step succeeds" "0" "$rc"
digests="$(output digests)"
head="$(output head)"
check "and records the head it rendered from" "$(git -C "$WORK/r" rev-parse HEAD)" "$head"

# --- the encoding of the output ------------------------------------------------
#
# A job output is one `key=value` line. A value with a line break in it would
# end the line, and the rest would be read as another output or refused, so the
# digests are one base64 line and decode to exactly the manifest.
check "the outputs are two lines, one per key" "2" "$(wc -l < "$WORK/gh-output" | tr -d ' ')"
check "and every line is a key=value pair" "0" "$(grep -vcE '^[a-z]+=[^[:space:]]+$' "$WORK/gh-output" || true)"
check "and the digests are on one line" "1" "$(grep -c '^digests=' "$WORK/gh-output")"
check "the digests decode to the manifest of the rendered bucket" \
	"$(bash "$HERE/scripts/artifacts/manifest-digests.sh" list "$WORK/r")" "$(printf '%s' "$digests" | base64 -d)"

# --- the commit job: a fresh clone of the same head, and the artifact ----------
# downloaded into its temporary directory
verify() { # $1 = case name; uses $digests and $head
	rm -rf "$WORK/k" "$WORK/k-tmp"
	git clone -q "$WORK/r" "$WORK/k"
	mkdir -p "$WORK/k-tmp"
	cp -R "$WORK/r-tmp/rendered" "$WORK/k-tmp/rendered"
	case "$1" in
	tampered | forged | added) tamper "$1" ;;
	esac
	rc=0
	( cd "$WORK/k" && RUNNER_TEMP="$WORK/k-tmp" RENDERED_DIGESTS="$digests" RENDERED_HEAD="$head" bash "$VERIFY" ) \
		> "$WORK/out" 2>&1 || rc=$?
}
tamper() { # $1 = case name
	local art="$WORK/k-tmp/rendered"
	if [ "$1" = added ]; then
		printf '{"version":"9"}\n' > "$art/bucket/evil.json"
		return
	fi
	printf ' ' >> "$art/bucket/podup.json"
	if [ "$1" = forged ]; then
		# The artifact carries a manifest of its own that matches its altered bytes.
		( cd "$art" && sha256sum bucket/podup.json ) > "$art/manifests.sha256"
	fi
}

verify good
check "the recorded bytes pass" "0" "$rc"
check "and are what the checkout now holds" "" "$(diff -r "$WORK/r/bucket" "$WORK/k/bucket")"
check "so the commit step sees the render's change" "bucket/podup.json" "$(git -C "$WORK/k" diff --name-only)"

verify tampered
check "a byte changed in the artifact is refused" "1" "$rc"
check "and the message says the files are not the recorded ones" "1" "$(grep -c 'are not the ones the render job recorded' "$WORK/out")"
check "and the checkout is untouched" "" "$(git -C "$WORK/k" status --porcelain)"

verify forged
check "a changed artifact carrying its own matching manifest is still refused" "1" "$rc"
check "and the checkout is untouched" "" "$(git -C "$WORK/k" status --porcelain)"

verify added
check "a file added to the artifact is refused" "1" "$rc"
check "and the checkout is untouched" "" "$(git -C "$WORK/k" status --porcelain)"

keep="$head"
head="0000000000000000000000000000000000000000"
verify good
check "a checkout at another parent than the render's is refused" "1" "$rc"
check "and the message names the parent" "1" "$(grep -c 'refusing to commit against another parent' "$WORK/out")"
head=""
verify good
check "no recorded head is a refusal too" "1" "$rc"
head="$keep"

keep="$digests"
digests=""
verify good
check "no recorded digests is a refusal, not a pass" "1" "$rc"
check "and the message says the manifest is missing" "1" "$(grep -c 'is missing or empty' "$WORK/out")"
digests="$keep"

# --- the roster is checked again in the commit job ---------------------------
# The record step does not judge what it records, so a render that wrote a
# manifest the roster refuses reaches the commit job with matching digests. The
# check in that job is what stops it, before the key is used.
render_and_record 0 yes
digests="$(output digests)"
head="$(output head)"
verify good
check "recorded bytes the roster refuses are stopped in the commit job" "1" "$rc"
check "by the manifest gate, not by the digests" "yes" "$(grep -q 'missing required top-level field' "$WORK/out" && echo yes || echo no)"
check "after the digests matched" "yes" "$(grep -q 'match the recorded digests' "$WORK/out" && echo yes || echo no)"

# --- the outputs cross from one job to the other ----------------------------
#
# What the engine does between the jobs: the render job's `outputs:` pick values
# out of the step outputs, and each step of the commit job is run or skipped by
# its own `if:`. This prints the steps of the commit job that would run, from
# the step outputs a real run of the render steps wrote.
plan() { # $1 = file of the render step's outputs, $2 = file of the record step's outputs
	python3 -I - "$WORKFLOW" "$1" "$2" <<'PY'
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))


def read(path):
    pairs = (l.split("=", 1) for l in open(path).read().splitlines() if "=" in l)
    return dict(pairs)


steps = {"render": read(sys.argv[2]), "digests": read(sys.argv[3])}
render = doc["jobs"]["render"]
needs = {}
for key, expr in (render.get("outputs") or {}).items():
    m = re.fullmatch(r"\$\{\{ steps\.(\w+)\.outputs\.(\w+) \}\}", expr)
    needs[key] = steps.get(m.group(1), {}).get(m.group(2), "") if m else ""
for step in doc["jobs"]["commit"]["steps"]:
    cond = step.get("if")
    if cond is None:
        run = True
    else:
        m = re.fullmatch(r"needs\.render\.outputs\.(\w+) (==|!=) '([^']*)'", str(cond))
        if not m:
            print(f"UNSUPPORTED {cond}")
            continue
        same = needs.get(m.group(1), "") == m.group(3)
        run = same if m.group(2) == "==" else not same
    if run:
        print(step.get("name") or step.get("uses", "").split("@")[0])
PY
}
run_plan() { plan "$WORK/render.out" "$WORK/digests.out" | tr '\n' '|'; }

render_and_record 0 valid
check "a clean render with a change runs the check, the mint and the commit" \
	"Refuse any ref but main|actions/checkout|Download the rendered manifests|Check the rendered bytes against the render job's digests|Mint a token for the updater app|Commit the update to main (GitHub-signed)|" \
	"$(run_plan)"

render_and_record 0 no
check "a clean render without a change still mints, and does nothing else" \
	"Refuse any ref but main|Mint a token for the updater app|" "$(run_plan)"

render_and_record 3 valid
check "a partial render with a change commits what rendered, then fails" \
	"Refuse any ref but main|actions/checkout|Download the rendered manifests|Check the rendered bytes against the render job's digests|Mint a token for the updater app|Commit the update to main (GitHub-signed)|Fail if any product was skipped|" \
	"$(run_plan)"
rc=0; ( cd "$WORK/r" && bash "$FAILSTEP" ) > "$WORK/out" 2>&1 || rc=$?
check "and the failure step fails the commit job" "1" "$rc"
check "and says what was skipped" "1" "$(grep -c 'skipped at least one product' "$WORK/out")"

render_and_record 3 no
check "a partial render without a change mints and fails" \
	"Refuse any ref but main|Mint a token for the updater app|Fail if any product was skipped|" "$(run_plan)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
