# Contributing to Glyndor/scoop-bucket

This repository has its own guide because the organisation's shared one
describes a `topic → develop → main` flow that does not exist here. Following
it would tell you to target a branch this repository does not have, and it
states that direct pushes to `main` are blocked with no exceptions. That is
false here, and deliberately so. See below.

Contributions are invitation-only. Bug reports and ideas through issues are
welcome; unsolicited pull requests are not accepted.

## What this repository is

It is the Scoop bucket for Glyndor's products. It carries no product source:
`bucket/*.json` is generated from each product's latest signed release, with
the release signature verified before anything is written. Edit
`scripts/release/render-manifests.sh`, never the manifests themselves: the next
scheduled run rewrites them whenever a product has a verified release to render, so a
hand edit is lost the next time its manifest is regenerated.

The renderer verifies the Ed25519 release signature, and the ML-DSA-65
signature a release may carry beside it. The second one is a hybrid and never
a replacement, so the Ed25519 signature is checked first and always. No product
carries that second signature yet, so every release today is admitted on the
Ed25519 signature alone.

**Its git content IS the published artifact.** A commit on `main` is what
`scoop install` reads. There is no build step between them and no CDN in front.

## The bot commits straight to main, and that is not an oversight

`update.yml` regenerates `bucket/` from each product's latest signed release and
commits the result to `main` directly, through the GraphQL
`createCommitOnBranch` mutation.

It cannot open a pull request instead: the organisation forbids GitHub Actions
from creating or approving them, and that setting is locked org-wide. A commit
that no pull request produced has no checks run on it, so the push needs a
bypass actor on the ruleset. `github-actions[bot]` cannot be one; a GitHub App
can. `glyndor-updater` is that app, installed on this repository with
`contents: write` and nothing else. The commit job mints a short-lived token from the
app's private key (`UPDATER_APP_PRIVATE_KEY`, a repository secret; the id is
the variable `UPDATER_APP_ID`), asked for with `permission-contents: write` and
no other permission, on every scheduled run, so a removed
installation or a broken key turns into a red run within the hour.

The ruleset on `main` otherwise applies to everyone, humans included, with no
bypass for them: pull request required (squash only), required checks with the
branch up to date, `required_signatures`, linear history and CodeQL. The
app's bypass covers the bot's push and nothing a human can do. Commits made
through `createCommitOnBranch` are GitHub-signed, which is how they satisfy
`required_signatures` without a signing key in this repository.

**The workflow runs two jobs, and the split is the security boundary.** `render`
installs the signature verifier, downloads each product's latest signed
release, re-renders `bucket/`, validates the result and records the SHA-256 of
every file it wrote. It holds no secret. `commit` mints the app's token, and
it installs nothing and runs no product's code: it checks the files it is
about to commit against the digests the render job recorded, and refuses
anything that does not match. The digests travel through the render job's
outputs, which no other job can write, and not through the artifact the two
jobs exchange: the commit job downloads that artifact and holds the token that
can upload one. `tests/publication/update/update-key-isolation.test.sh` reads the
workflow and fails if another job references a secret or the commit job installs
something, and `tests/publication/update/update-digest-handoff.test.sh` runs the
two steps that pass the digests from one job to the other.

**The validation that runs INSIDE `update.yml` before the commit is the only
gate between a bad render and `scoop install`**, because the bot's push skips
the required checks. It runs in the render job and again in the commit job, on
the bytes that job is about to commit. It is covered by `tests/publication/update/update-workflow.test.sh`, which
extracts the workflow's own `run:` blocks and executes them as they ship
rather than against a copy.

`dco-on-main.yml` stays as detection for anything that lands without a pull
request: an unsigned human commit would be a red run within a minute.

## Intentional release rollbacks

The renderer refuses versions below the served version using SemVer precedence
(pre-releases precede stable releases; build metadata does not affect ordering).
For a reviewed rollback, take two pull requests. First merge one that adds a line
`bucket/<name>.json <committed version> <version to go back to>` to
`scripts/artifacts/approved-rollbacks.txt`: the permission is read from the base
branch, so it cannot arrive together with the rollback, and the version gate then
lets exactly that manifest go between exactly those two versions and refuses
anything else. The rollback pull request must also delete the line: an approval is
single-use, and the gate refuses a tree that is already at the version a line allowed.
A pull request that rolls something back may only delete lines; adding or changing one
in the same change is refused. A malformed approvals file on the base branch grants
nothing, so the pull request that repairs it can pass. For the second, make the
desired signed release `latest`: the hourly updater renders each product's latest
release, so otherwise its next run replaces your change. Then run
`ALLOW_RELEASE_DOWNGRADE=1 ./scripts/release/render-manifests.sh` manually, validate with
`./scripts/artifacts/check-manifests.sh`, and submit the generated diff through a pull request.
The override logs a warning naming the product and both versions; signature and
provenance checks still apply. `update.yml` never sets this variable, including
on `workflow_dispatch`, so dispatching the scheduled updater cannot enable it.

## Branch flow

```
topic branch ──PR──▶ main
```

There is no `develop`. Branch from `main`, open a pull request against
`main`, squash-merge back.

`Closes #N` auto-closes, because the fix lands on the default branch.

## Before you open a pull request

- **An issue first.** Labels are the tracking system; there is no board. Apply
  `type:`, `prio:`, `effort:`, `status:` and `area:` where they fit.
- **Sign every commit off** by running `git commit -s`. The `dco` check is
  required on pull requests.
- **Commits are signed**, GPG or SSH. `required_signatures` is enforced on
  `main`, and rebase-merge is disabled because GitHub re-creates rebased
  commits without signatures.
- **Conventional Commit title** on the pull request.

## Tests

The suites need `shellcheck`, `jq`, `python3-yaml` and `python3-cryptography` installed. In CI, shellcheck is the pinned release the shellcheck job uses, and a pull request installs only what the suites it selects need (`scripts/quality/suite-dependencies.txt`).

```sh
fail=0
suite=$(find tests -name '*.test.sh' -type f | sort)
# The completeness check takes the other test files as arguments and runs them
# itself, so this command runs each suite exactly once. On its own it only
# prints its usage.
# shellcheck disable=SC2086
# A runner that is not executable must fail the command, not skip the suites.
if [ -x tests/ci/suites/check-suite-completeness.test.sh ]; then
  tests/ci/suites/check-suite-completeness.test.sh $(grep -v check-suite-completeness <<< "$suite") || fail=1
else
  echo "FAILED: tests/ci/suites/check-suite-completeness.test.sh is not executable"; fail=1
fi
find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck || fail=1
[ "$fail" -eq 0 ] && echo "all green" || echo "SOMETHING FAILED"
[ "$fail" -eq 0 ]
```

Keep the flag. The runner carries on past a failure -- it runs every suite and
counts the failures -- but its exit status says only that something failed.
The `FAIL` lines it prints are what say which, and they scroll. The flag turns
them back into something a script can read. This is the command the workflow
runs, so a local run and a CI run judge the same thing.

`tests/release/release-signature/release-signature-mldsa.test.sh` also needs
`cryptography` 50.0.2 or later, for ML-DSA-65, which no Ubuntu release packages
yet. Without it that suite fails and says so, and the command above goes red.
Install the pinned wheel into a virtual environment that still sees the system
packages, and put it first on `PATH` before running the command:

```bash
python3 -m venv --system-site-packages ~/.cache/bucket-mldsa
~/.cache/bucket-mldsa/bin/python -m pip install --require-hashes --only-binary=:all: \
  -r scripts/release/render-requirements.txt
export PATH="$HOME/.cache/bucket-mldsa/bin:$PATH"
```

CI runs that suite in its own job, `ML-DSA-65 verifier` in `tests.yml`.

**Every script in `scripts/` needs a test.**
`scripts/quality/check-test-coverage.sh` fails when one does not, itself included --
it lives in `scripts/`, so deleting its test makes it report itself.

**Every test must be wired into a workflow.**
`tests/ci/suites/ci-runs-every-test.test.sh` fails when one is not. An unregistered test
sits in `tests/`, passes by hand, and reads as coverage while CI never runs
it. That happened in the sibling `apt` repository and went unnoticed for a day.
So does the `workflow-lint` check, which runs `scripts/quality/check-suites-wired.sh`
outside the test job: a pull request that drops the watcher from the list along
with other suites leaves the test job green, and turns that check red.
A suite that cannot run on a pull request goes in `scripts/quality/suite-exemptions.txt`
with its reason. That list is read from the base commit too, so an entry takes
effect from the pull request after the one that adds it.

**A new suite needs an entry in `scripts/quality/suite-scope.txt`.**
On a pull request the runner skips the suites whose paths the change does not
touch, so a suite with no entry would run every time and
`tests/quality/ci-job-scope-suites.test.sh` fails until it has one. List every
path the suite reads: a missing path lets a change merge without the suite that
should have judged it, while an extra one only costs a run. A change to the map,
to `scripts/quality/ci-job-scope.sh` or to the runner runs everything, and both
files are shared byte for byte with the sibling channel repository, so they
change in both together.

**A test you have not watched fail is not a test.** Before claiming a check
works, delete or invert the control it covers and confirm it goes red for the
reason it names. Four ways that goes wrong: the change you made changed nothing; it changed
something the test does not look at; the test went red, but for a reason other
than the one it names; or the same tool that made the change also confirmed it.
Confirm from something that took no part in the change, and read the failure
message, not the colour.

Assert **which** failure fired, never that some failure did. Scripts run under
`set -euo pipefail`, so almost any mistake exits non-zero.

Two failures that only appear after the commit:

**The mode in the index, not the mode on disk.** Where `core.fileMode=false` is
set, `chmod +x` changes nothing git records, and a test file that landed
`100644` gives exit 126 on the runner and stops every suite after it. Check with
`git ls-files -s tests/` and fix with
`git update-index --chmod=+x tests/<name>.test.sh`.

**A missing final newline hides until the file is tracked.** The editorconfig
checker walks tracked files on purpose, and a test holds it to that, so run it
after staging or it will tell you a new file is fine when it is not.

**A new guard brings its catalogue entry.** A change that adds a refusal under
`scripts/` adds the line of `tests/mutation/catalog.txt` that breaks it and names the
suite that notices; `tests/mutation/run-mutations.sh <id>` runs that one entry.
`tests/mutation/catalog-reaches-every-script.test.sh` fails a script that no entry
mutates at all. A guard added to a file that already has entries is for the review to
catch, because a count per file cannot tell one guard from another.

## Workflows

| file | what a red means |
|---|---|
| `tests.yml` | four jobs. `shell`: a suite or shellcheck. `ML-DSA-65 verifier`: the second signature verified with real ML-DSA-65 keys, in a virtual environment built from `scripts/release/render-requirements.txt`, so a red there can be that pinned wheel failing to install as well as the verifier. `products match the generator`: `bucket/` no longer matches `PRODUCTS`. `validate manifests`: a manifest is malformed, or goes back to an older release |
| `pr-hygiene.yml` | the pull request itself is malformed |
| `freshness.yml` | something scheduled stopped happening elsewhere, or a tool pinned in a reusable fell behind its upstream release |
| `published-bytes.yml` | a published manifest is invalid, does not declare a Glyndor release asset, or its digest does not match the bytes its URL serves |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `update.yml` | the hourly regeneration: `render` renders and validates, `commit` mints the app's token and commits to `main` |
| `drift.yml` | a copy this repository shares with a sibling channel no longer agrees: a reusable workflow, the renderer's verification logic, or one of the scripts and tests the bucket and the tap carry as exact copies |
| `dco-on-main.yml` | a human commit reached `main` without a `Signed-off-by` trailer; detection after the push, not prevention |
| `mutation.yml` | a guard of `scripts/` was weakened and no suite noticed; the weekly sweep breaks each guard on purpose and requires a suite to see it |

Every reusable lives in `.github/workflows/reusable-*.yml` as a copy kept identical in logic to the
copies in the sibling channels (`scripts/monitoring/check-reusable-drift.sh` compares
them). The scripts and tests listed in `scripts/monitoring/channel-shared-paths.txt` are
copies kept identical to the tap's (`scripts/monitoring/check-channel-drift.sh` compares them).
The comparison does fetch the sibling copies, read-only and size-capped, from `raw.githubusercontent.com`; it runs in `drift.yml`, and the test job fetches nothing.

**Job ids are load-bearing.** A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check.
Move jobs between files freely; renaming one is a ruleset change.

## Security

Never open a public issue for a vulnerability. Use the Security tab →
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and
is deliberately not duplicated.
