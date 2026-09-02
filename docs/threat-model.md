# Threat model

What this bucket protects, against whom, with which control, and how each
control is known to work. The README says how to install and what a user is
trusting; this page is the assessor's view: one row per threat, the control that
answers it, and the evidence that the control is real. Residual risks come last,
on purpose.

Evidence is of two kinds. A **test** is a case under `tests/` that fails when
the control is removed from the file it covers; it is cited by file, line and
case name. A **measurement** is a number or a fact read off the tree on the
date given. Where neither exists the word is **none**. Every `path:line` below
was read on 2026-09-02; lines move, case names do not.

## What this repository is, and is not

- **Git is the artifact.** `scoop bucket add` clones this repository and
  `scoop install` reads `bucket/*.json` from that clone (`README.md:16-23`,
  `CONTRIBUTING.md:21-22`). No server, no CDN and no custom domain sit in the
  path (`README.md:48-49`), so there is nothing to serve stale and nothing to
  purge.
- **A Scoop bucket is a git repository of manifests, not a storage bucket.**
  The apt archive's "bucket" is object storage; this one has none.
- **No binary lives here.** Each manifest points at the product's own GitHub
  release (`bucket/podup.json:8,18`) and carries a version, a URL and a hash per
  architecture, and a `bin` mapping (`bucket/podup.json:1-28`).
- **Windows only** (`scripts/render-manifests.sh:7-8`). There is no winget
  manifest and none is planned: winget means a pull request into
  `microsoft/winget-pkgs` on every release, and the owner declined that.
- **Pull-based.** No product pushes here and none holds a credential on this
  repository (`.github/workflows/update.yml:3-8`, `README.md:61-62`).

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| The manifests | `bucket/*.json`, one per row of `PRODUCTS` (`scripts/render-manifests.sh:75-77`) | what `scoop install` reads; the commit is the release |
| The rendered hashes | `architecture.<arch>.hash` (`bucket/podup.json:9,19`) | the only thing binding a download to the verified release; copied from a signed `SHA256SUMS`, never computed from the asset (`scripts/render-manifests.sh:161-182`) |
| The organization's Ed25519 release public key | `RELEASE_PUBKEY_B64` (`scripts/render-manifests.sh:25`), with a second slot (`:37`) | the trust anchor; a wrong value fails every render closed (`:22-24`) |
| `main` | the branch the bot commits to (`.github/workflows/update.yml:129-166`) and Scoop clones | it is the published artifact; no build and no review stand between a commit and `scoop install` |

## Trust boundaries and actors

- **A product's GitHub release.** Untrusted. The tag, `SHA256SUMS` and the
  assets are attacker-influenced until `SHA256SUMS.sig` verifies against the
  release key (`scripts/render-manifests.sh:159-160`, `:244-247`). The tag stays
  untrusted after that, because it travels beside the signature rather than
  inside it (`:213-216`).
- **GitHub.** Hosts the repository, the releases and the runner, and signs the
  bot's commit (`.github/workflows/update.yml:136-139`). Trusted; see out of
  scope.
- **The update bot.** `update.yml`, hourly (`:47`), running as `GITHUB_TOKEN`
  (`:89`, `:132`) with `contents: write` on its one job (`:68-69`) over a
  workflow default of `contents: read` (`:55-56`). It commits through the
  GraphQL `createCommitOnBranch` mutation (`:156`). No long-lived credential
  exists in this repository.
- **A human with Write.** Invitation-only (`CONTRIBUTING.md:9-10`); one owner
  (`.github/CODEOWNERS:2`). Can merge a pull request into `main` and is not
  stopped by a required check, because the ruleset has none
  (`CONTRIBUTING.md:35-39`).
- **A Windows user.** Runs the three lines in `README.md:16-20`. Scoop clones
  `main` and refuses a download whose bytes do not match the pinned hash
  (`README.md:48-50`). That comparison is Scoop's; this repository does not
  test it.

## Threats and controls

### The release

| Threat | Control | Evidence |
|---|---|---|
| A release asset is tampered with (the bytes differ from what the product signed) | the manifest hash comes from `SHA256SUMS` after its signature verified, so the tampered download fails Scoop's hash check | test: `tests/render-manifests.test.sh:166` "the 64bit hash is the one the signed manifest declares" |
| `SHA256SUMS.sig` is missing, altered or signed by someone else | `verify_sha256sums` fails closed (`scripts/render-manifests.sh:83-149`): the product is skipped, its manifest untouched, and the job ends red (`.github/workflows/update.yml:168-176`) | test: `tests/render-manifests.test.sh:186` "an unverifiable signature skips the product", `:187` "and writes no manifest", `:212` "the run still fails, so the skip is not silent" |
| The signing key is wrong, stale or rotated under the bucket | a key that did not sign the release fails every render; no environment variable can replace the constant (`scripts/render-manifests.sh:39-44`) | test: `:238` "the environment cannot swap the trust anchor", `:353` "a well-formed key that did not sign it fails as a signature", `:269` "two wrong keys still fail closed" |
| `SHA256SUMS` is well signed but malformed (an asset listed twice, a non-hex or short digest) | `hash_of` demands exactly one 64-character hex entry per asset (`scripts/render-manifests.sh:161-182`) | test: `:363` "an asset listed twice is rejected", `:377` "a non-hexadecimal checksum is rejected", `:389` "a short digest is rejected" |
| A release tag carries code or a path | the version is held to a fixed character set before it is interpolated (`scripts/render-manifests.sh:229-241`) | test: `:286` "a release tag carrying code is refused" |
| A compromised product repository publishes a malicious release under a valid signature | **none.** The bucket proves the release is the one the product signed, not that it is safe. The signing key lives in the product's release job (`.github/workflows/update.yml:38-39`), so whoever controls that job signs what they like; the bucket renders it within the hour and validation passes it. It also compares no versions, so an older release re-signed and published as latest is rendered as is. What the bucket does refuse: a tag outside the version alphabet, a `SHA256SUMS` that does not verify, a listed-twice or malformed digest. The rest is the product's threat model | measurement: `scripts/render-manifests.sh` contains no version comparison, 2026-09-02 |

### `main`

| Threat | Control | Evidence |
|---|---|---|
| A human with Write commits a malicious manifest | three partial controls and a named gap. (1) `required_signatures` on `main` (`CONTRIBUTING.md:36-37`), the compensating control for having no require-PR and no required check, both of which would reject the bot's push (`CONTRIBUTING.md:30-35`). (2) The next hourly render overwrites a hand edit for any product whose release renders (`scripts/render-manifests.sh:289-302`, `CONTRIBUTING.md:17-19`). (3) `dco-on-main.yml` reports a human commit without `Signed-off-by` after it lands (`.github/workflows/dco-on-main.yml:36-38`, `scripts/check-dco-on-main.sh:84-92`); the pull request `dco` check runs but is not required (`CONTRIBUTING.md:71-73`). The gap: validation reads structure only (`scripts/check-manifests.sh:36-42`), so a signed, hand-committed manifest whose `url` points elsewhere passes, and if that product's release stops rendering the hand edit is kept (`scripts/render-manifests.sh:319-323`) | test for (3): `tests/check-dco-on-main.test.sh:72` "an unsigned human commit fails", `:112` "a commit whose author field impersonates the bot is still reported". (1) is a ruleset, not in the tree. (2): `tests/render-manifests.test.sh:213` "the skipped product keeps the manifest it had" pins the gap, not the control |
| A manifest `url` points outside the product's GitHub release | on the rendered path the URL is built from the `PRODUCTS` repository and the verified tag, never read from the release (`scripts/render-manifests.sh:271`, `:278`, `:283`) | test: `tests/render-manifests.test.sh:163` "the 64bit url points at the tagged asset". On the human path: none, see the row above |
| A manifest that is not JSON, lacks a field, or an emptied `bucket/` reaches `main` | `scripts/check-manifests.sh` runs inside the job before the commit (`.github/workflows/update.yml:113-127`) and on every push and pull request (`.github/workflows/tests.yml:75-89`); an empty bucket is an error, not a vacuous pass (`scripts/check-manifests.sh:30-33`) | test: `tests/check-manifests.test.sh:123` "a file that is not JSON is refused", `:132` "an empty bucket is refused rather than passing vacuously", `:101` per-architecture fields; `tests/update-workflow.test.sh:162` "an emptied bucket/ fails validation" |
| The bot's commit lands unsigned, or on a `main` that moved since checkout | `createCommitOnBranch` with `expectedHeadOid` (`.github/workflows/update.yml:140-143`, `:156`); the concurrency group serialises runs (`:60-62`) | test: `tests/update-workflow.test.sh:244` "the payload uses createCommitOnBranch", `:246` "and pins expectedHeadOid" |
| `bucket/` disagrees with `PRODUCTS` | `scripts/check-products-consistent.sh` on every push and pull request (`.github/workflows/tests.yml:59-73`) | test: `tests/check-products-consistent.test.sh:68` "a missing manifest file fails" |

What `jq` checks in `scripts/check-manifests.sh:36-42`: a non-empty `version`
string, `homepage` and `license` strings, a non-empty `architecture` object,
and a truthy `url` and `hash` plus a `bin` array per architecture. What it
cannot check: that the hash matches any bytes, that the URL is on
`github.com`, that the version matches the tag, or that the hash is 64 hex
characters. The renderer checks that last one (`scripts/render-manifests.sh:171-180`);
nothing checks the other three on a hand-committed file.

### The job

| Threat | Control | Evidence |
|---|---|---|
| The update job stalls (dark cron, rotated key, GitHub outage) and the bucket freezes silently | `freshness-update` fails when the newest successful scheduled run of `update.yml` is older than `max-age-days: 3` (`.github/workflows/freshness.yml:55-62`); it runs twice daily and on every push and pull request (`:40-44`), and a second watcher watches it (`:83-90`) | test: `tests/reusable-schedule-freshness.test.sh:120` "an 11-day-old run fails the 10-day limit", `:132` "no successful run on record fails". The caller's inputs are read, not tested |
| A hung run holds the concurrency group | `timeout-minutes: 10` against a measured 13 to 20 seconds (`.github/workflows/update.yml:70-75`) | none; measurement read off `update.yml:75`, 2026-09-02 |
| A checkout persists the job token | `persist-credentials: false` on every checkout | measurement: 12 `actions/checkout` steps, 12 with the flag, 2026-09-02; no test |
| A third-party action runs in CI | every `uses:` is a local reusable (`./.github/workflows/reusable-*.yml`) or a GitHub-owned action pinned by full SHA: `actions/checkout`, `actions/setup-go`, `actions/cache` (`.github/workflows/reusable-workflow-lint.yml:48,66,70`). The reusables are copies taken from a named tag and compared daily with the sibling channels (`.github/workflows/drift.yml:71-80`, `scripts/check-reusable-drift.sh:6-9`) | measurement: `grep -n 'uses:' .github/workflows/*.yml`, 2026-09-02; none as a test. The tooling-isolation assertion (`reusable-workflow-lint.yml:158-272`) refuses `cargo`, `go`, `gem`, `npm` and unpinned `pip` installs in a job that references `secrets.*`; `update.yml` holds only `github.token`, which that pattern does not match, and installs `python3-cryptography` with `apt-get` from the runner's own archive (`update.yml:81-84`) |
| A test exists and nothing runs it; a script exists and nothing tests it | `tests/ci-runs-every-test.test.sh` and `scripts/check-test-coverage.sh`, each including itself (`scripts/check-test-coverage.sh:4-8`) | test: `tests/ci-runs-every-test.test.sh:59` "every test in tests/ is invoked by a workflow", `:75` "this watcher is itself invoked by a workflow" |
| A `run:` block in `update.yml` is edited and no test notices | the suite extracts the workflow's own `run:` blocks and executes them as they ship (`tests/update-workflow.test.sh:16-17`, `:50-66`) | test: `:114-119`, three "was extracted from the workflow" cases |

## Key rotation

The renderer carries two key slots (`scripts/render-manifests.sh:25`, `:37`),
and a release verifies if any configured key signed it; an empty slot is not a
key, and exhausting both is an error (`:98-101`, `:140-147`). The organization's
rotation is make-before-break (`:27-36`):

1. Put the new public key in `RELEASE_PUBKEY2_B64` here, in the Homebrew tap's
   renderer, and in every product verifier, and merge.
2. Products publish a release signed with the new key.
3. Once every consumer carries both, move the new key into the first slot and
   empty the second.

The ordering that breaks it is step 2 before step 1. Every render then fails
signature verification, no manifest changes, the job is red every hour, and
the bucket stays on the last version it could verify until the freshness
watcher goes red at three days. Nothing wrong ships; the channel stops.

Tests: `tests/render-manifests.test.sh:258` "a release signed by the second key
still verifies", `:262` "the first key alone still verifies", `:269` "two wrong
keys still fail closed".

## Residual risks

Accepted by the owner; recorded here so they are read as decisions rather
than oversights.

- **DCO on human commits is detection, not prevention**
  (`.github/workflows/dco-on-main.yml:3-15`). Every route to prevention was
  priced and declined (`CONTRIBUTING.md:45-54`). Uncovered: a human who sees
  the red run and merges anyway.
- **One maintainer** (`.github/CODEOWNERS:11-16`). A required check is matched
  by name, so a pull request with Write can replace a caller with a stub that
  emits the name. The mitigation, Code Owner review on `.github/workflows/`,
  waits for the day a second human gets access.
- **No field test on Windows hardware.** The manifest renders, validates, and
  was rendered from a real signed release; no `scoop install` has been run on
  a Windows machine by this repository. Stated here, not measured in the tree.
- **Monitoring shares fate with the monitored.** The update job and both
  freshness watchers run on GitHub Actions; an outage there stops the channel
  and its alarm together.
- **The release key is shared across products** and held by each product's
  release job. This repository can rotate what it trusts; it cannot see a
  compromise upstream.

## Out of scope

- **A compromised GitHub.** It hosts the repository, the releases and the
  runner, and it signs the bot's commits.
- **A compromised product build pipeline.** A binary that was malicious before
  it was signed is admitted with a valid signature.
- **The user's machine.** Scoop's clone, its hash check, and everything after
  `scoop install`.
- **Scoop itself.**

## How to verify this document

```sh
git clone https://github.com/Glyndor/scoop-bucket && cd scoop-bucket
grep -n 'RELEASE_PUBKEY' scripts/render-manifests.sh             # the two slots
grep -n 'timeout-minutes\|group:\|contents:' .github/workflows/update.yml
grep -c 'persist-credentials: false' .github/workflows/*.yml     # one per checkout
grep -n 'uses:' .github/workflows/*.yml                          # no third-party action
./tests/render-manifests.test.sh                                 # signature, slots, tag, digests
./tests/update-workflow.test.sh                                  # the job's own run: blocks
./tests/check-manifests.test.sh                                  # what jq refuses
./tests/check-dco-on-main.test.sh                                # detection on main
```

A control is only as real as its red. Delete it from the file the row names,
run the suite, and the case cited must fail for the reason it names. Where a
row says "none", there is nothing to delete; that is the finding.

## Reporting

Report vulnerabilities privately through the repository's Security tab
(`README.md:68-69`, `CONTRIBUTING.md:128-132`).
