# Threat model

What this bucket protects, against whom, with which control, and how each
control is known to work. The README says how to install and what a user is
trusting; this page is the assessor's view: one row per threat, the control that
answers it, and the evidence that the control is real. Residual risks come last,
on purpose.

Evidence is of two kinds. A **test** is a case under `tests/` that fails when
the control is removed from the file it covers; it is cited by file and case
name. A **measurement** is a number or a fact read off the tree on the
date given. Where neither exists the word is **none**. A reference on this
page names the thing it points at -- a function, a constant, a job, a heading
-- and never a line number. The references were read as `path:line` on
2026-09-02 and were true that day; the renderer grew, moved directory, and the
numbers went on pointing at unrelated code while this page still read as if it
were current. Nothing noticed, because a line number in a Markdown document is
not a link and nothing resolves it.
`scripts/quality/check-doc-anchors.sh` resolves every reference below and
fails when one does not. Release admission and validator boundaries were
checked again on 2026-10-31 against the current renderer and tests.

## What this repository is, and is not

- **Git is the artifact.** `scoop bucket add` clones this repository and
  `scoop install` reads `bucket/*.json` from that clone (`README.md#Install`,
  `CONTRIBUTING.md#The bot commits straight to main, and that is not an oversight`).
  No server, no CDN and no custom domain sit in the
  path (`README.md#What you are trusting`), so there is nothing to serve stale
  and nothing to purge.
- **A Scoop bucket is a git repository of manifests, not a storage bucket.**
  The apt archive's "bucket" is object storage; this one has none.
- **No binary lives here.** Each manifest points at the product's own GitHub
  release (`bucket/podup.json#url`) and carries a version, a URL and a hash per
  architecture, and a `bin` mapping (`bucket/podup.json#architecture`).
- **Windows only** (`scripts/release/render-manifests.sh#PRODUCTS`). There is no winget
  manifest and none is planned: winget means a pull request into
  `microsoft/winget-pkgs` on every release, and the owner declined that.
- **Pull-based.** No product pushes here and none holds a credential on this
  repository (`.github/workflows/update.yml#update`, `README.md#What you are trusting`).

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| The manifests | `bucket/*.json`, one per row of `PRODUCTS` (`scripts/release/render-manifests.sh#PRODUCTS`) | what `scoop install` reads; the commit is the release |
| The rendered hashes | `architecture.<arch>.hash` (`bucket/podup.json#hash`) | the only thing binding a download to the verified release; copied from a signed `SHA256SUMS` and compared with the downloaded asset digest before rendering (`scripts/release/render-manifests.sh#hash_of`, `scripts/release/render-manifests.sh#verify_attestation`) |
| The organization's Ed25519 release public key | `RELEASE_PUBKEY_B64` (`scripts/release/render-manifests.sh#RELEASE_PUBKEY_B64`), with a second slot (`scripts/release/render-manifests.sh#RELEASE_PUBKEY2_B64`) | the trust anchor; a wrong value fails every render closed (`scripts/release/render-manifests.sh#verify_sha256sums`) |
| `main` | the branch the bot commits to (`.github/workflows/update.yml#Commit the update to main (GitHub-signed)`) and Scoop clones | it is the published artifact; no build and no review stand between a commit and `scoop install` |

## Trust boundaries and actors

- **A product's GitHub release.** Untrusted input. The Ed25519 signature
  authenticates the bytes of `SHA256SUMS`, including its asset names and
  digests; it does not authenticate the adjacent tag. For every published
  asset, `scripts/release/render-manifests.sh#verify_attestation` downloads the bytes, compares their SHA-256
  with that signed entry, and requires provenance verified by `gh` for the
  `PRODUCTS` repository, `refs/tags/<tag>` and that repository's
  `.github/workflows/release.yml`. The tag is therefore checked through
  each asset's provenance before rendering. This establishes origin, not
  whether the build or its source is safe.
- **GitHub.** Hosts the repository, the releases and the runner, and signs the
  bot's commit (`.github/workflows/update.yml#Commit the update to main (GitHub-signed)`). Trusted; see out of
  scope.
- **The update bot.** `update.yml`, hourly. The job itself runs on a
  read-only `GITHUB_TOKEN` (`contents: read`). The write goes through a token
  minted for the `glyndor-updater` GitHub App (`contents: write` on this
  repository only) by `actions/create-github-app-token`, from a long-lived
  private key held as the repository secret `UPDATER_APP_PRIVATE_KEY`. The app
  is a bypass actor on the `main` ruleset. It commits through the GraphQL
  `createCommitOnBranch` mutation. A leaked key would let its holder push to
  `main` past the required checks, which is why the key is the credential that
  matters here.
- **A human with Write.** Invitation-only (`CONTRIBUTING.md`); one owner
  (`.github/CODEOWNERS#*`). Has no bypass: the ruleset requires a pull request,
  eight status checks with the branch up to date, signed commits and CodeQL, so
  a human change reaches `main` only through a reviewed-by-CI pull request.
- **A Windows user.** Runs the three lines in the README. Scoop clones
  `main` and refuses a download whose bytes do not match the pinned hash
  (`README.md#What you are trusting`). That comparison is Scoop's; this repository does not
  test it.

## Threats and controls

### The release

| Threat | Control | Evidence |
|---|---|---|
| A release asset is tampered with (the bytes differ from what the product signed) | the manifest hash comes from `SHA256SUMS` after its signature verified, so the tampered download fails Scoop's hash check | test: `tests/release/render-manifests.test.sh#the 64bit hash is the one the signed manifest declares` |
| `SHA256SUMS.sig` is missing, altered or signed by someone else | `verify_sha256sums` fails closed (`scripts/release/render-manifests.sh#verify_sha256sums`): the product is skipped, its manifest untouched, and the job ends red (`.github/workflows/update.yml#Fail if any product was skipped`) | test: `tests/release/render-manifests.test.sh#an unverifiable signature skips the product`; `tests/release/render-manifests.test.sh#and writes no manifest`; `tests/release/render-manifests.test.sh#the run still fails, so the skip is not silent` |
| The signing key is wrong, stale or rotated under the bucket | a key that did not sign the release fails every render; no environment variable can replace the constant (`scripts/release/render-manifests.sh#RELEASE_PUBKEY_B64`) | test: `tests/release/render-manifests.test.sh#the environment cannot swap the trust anchor`; `tests/release/render-manifests.test.sh#a well-formed key that did not sign it fails as a signature`; `tests/release/render-manifests.test.sh#two wrong keys still fail closed` |
| `SHA256SUMS` is well signed but malformed (an asset listed twice, a non-hex or short digest) | `hash_of` demands exactly one 64-character hex entry per asset (`scripts/release/render-manifests.sh#hash_of`) | test: `tests/release/render-manifests.test.sh#an asset listed twice is rejected`; `tests/release/render-manifests.test.sh#a non-hexadecimal checksum is rejected`; `tests/release/render-manifests.test.sh#a short digest is rejected` |
| A release tag carries code or a path | the version is held to a fixed character set before it is interpolated (`scripts/release/render-manifests.sh#version_guard`) | test: `tests/release/render-manifests.test.sh#a release tag carrying code is refused` |
| An old asset is re-uploaded under a newer tag with its old signed checksums | each non-dash asset must match its signed digest and pass provenance verification for the candidate tag, repository and release workflow | `scripts/release/render-manifests.sh#verify_attestation`; `tests/release/render-manifests/render-manifests-attestation.test.sh#an attestation naming a different tag is refused`; `tests/release/render-manifests.test.sh#a second asset with provenance for another tag is refused` |
| An older, validly signed and attested release becomes latest | the renderer compares the candidate and served SemVer versions before writing or pruning and rejects a downgrade as a fatal error. Equal precedence (including different build metadata) is allowed. A manual `ALLOW_RELEASE_DOWNGRADE=1` override permits rollback and logs a warning; the scheduled workflow does not set it | test: `tests/release/render-manifests/render-manifests-attestation.test.sh#an inactive bypass still refuses the downgrade`; `tests/release/render-manifests/render-manifests-attestation.test.sh#an explicit rollback succeeds`; `tests/release/render-manifests/render-manifests-attestation.test.sh#the rollback is visible in the log`; `tests/release/render-manifests/render-manifests-attestation.test.sh#equal build precedence is rendered for the new tag, not refused (one URL per architecture)` |
| A compromised product build pipeline publishes malicious bytes with a valid signature and matching provenance | admission proves the signed digest and claimed build origin, not good intent. A workflow that controls signing and produces trusted provenance can still publish malicious code under an admissible version. An older release cannot replace a newer served version by default; an initial render without a served version, equal-precedence replacement and the explicit rollback override remain bounded replay risks | `scripts/release/render-manifests.sh#verify_sha256sums`; `scripts/release/render-manifests.sh#verify_attestation`; `scripts/release/render-manifests.sh#release_order`; `scripts/release/render-manifests.sh#render_product`; build safety is outside this bucket's scope |

### `main`

| Threat | Control | Evidence |
|---|---|---|
| A human with Write commits a malicious manifest | three partial controls and a named gap. (1) the ruleset on `main`: pull request required, required status checks, `required_signatures`, no bypass for humans (it is a ruleset, not in the tree). (2) The next hourly render overwrites a hand edit for any product whose release renders (`scripts/release/render-manifests.sh#render_product`, `CONTRIBUTING.md#The bot commits straight to main, and that is not an oversight`). (3) `dco-on-main.yml` reports a human commit without `Signed-off-by` after it lands (`.github/workflows/dco-on-main.yml#Check the pushed commits`, `scripts/governance/check-dco-on-main.sh#exempt_all`); the pull request `dco` check is required. The gap: validation restricts keys, types, URL shape and digest format, and holds the URL to the product the roster names and the tag the manifest's version implies, but does not bind a hand edit to the product's signed release. Another executable mapping or another well-formed hash can pass. If that product's release stops rendering, the hand edit is kept | test for (3): `tests/governance/check-dco-on-main.test.sh#an unsigned human commit fails`; `tests/governance/check-dco-on-main.test.sh#a commit whose author field impersonates the bot is still reported`. (1) is a ruleset, not in the tree. (2): `tests/release/render-manifests.test.sh#the skipped product keeps the manifest it had` pins the gap, not the control |
| A manifest `url` points outside the product's GitHub release | the validator holds every `url` to the release of the product that manifest publishes: the repository comes from the row that names the manifest in `PRODUCTS` (`scripts/release/render-manifests.sh#PRODUCTS`), and the tag has to be the `v<version>` the manifest itself declares (`scripts/artifacts/check-manifests.sh#check-manifests`). A url for another Glyndor repository, or for another tag of this one, is refused by name. On the rendered path the URL is built from the `PRODUCTS` repository and the verified tag, never read from the release (`scripts/release/render-manifests.sh#render_product`) | test: `tests/release/render-manifests.test.sh#the 64bit url points at the tagged asset`; the validator's own cases are in `tests/artifacts/check-manifests.test.sh`. The url is bound to the product and the version, not to the bytes a release published: see the row above |
| A manifest that is not JSON, lacks a field, or an emptied `bucket/` reaches `main` | `scripts/artifacts/check-manifests.sh` runs inside the job before the commit (`.github/workflows/update.yml#Validate the re-rendered manifests`) and on every push and pull request (`.github/workflows/tests.yml#manifests`); an empty bucket is an error, not a vacuous pass (`scripts/artifacts/check-manifests.sh#check-manifests`) | test: `tests/artifacts/check-manifests.test.sh#a file that is not JSON is refused`; `tests/artifacts/check-manifests.test.sh#an empty bucket is refused rather than passing vacuously`; `tests/artifacts/check-manifests.test.sh#a per-architecture field the renderer does not emit is refused`; `tests/publication/update/update-workflow.test.sh#an emptied bucket/ fails validation` |
| The bot's commit lands unsigned, or on a `main` that moved since checkout | `createCommitOnBranch` with `expectedHeadOid` (`.github/workflows/update.yml#Commit the update to main (GitHub-signed)`); the concurrency group serialises runs (`.github/workflows/update.yml#update`) | test: `tests/publication/update/update-workflow.test.sh#and the payload uses createCommitOnBranch`; `tests/publication/update/update-workflow.test.sh#and pins expectedHeadOid` |
| `bucket/` disagrees with `PRODUCTS` | `scripts/artifacts/check-products-consistent.sh` on every push and pull request (`.github/workflows/tests.yml#products`) | test: `tests/artifacts/check-products-consistent.test.sh#a missing manifest file fails` |

`scripts/artifacts/check-manifests.sh#check-manifests` is a structural gate, not a signature
verifier. It restricts keys and architectures, checks required fields and
`bin` entry types, requires a canonical HTTPS Glyndor release asset URL and a
lowercase 64-hex hash. It rejects an external host, path traversal in a URL,
query strings, malformed hashes and extra installation hooks. The URL is bound
to its product as well: the repository is the one the row that names the
manifest declares in `PRODUCTS` (`scripts/release/render-manifests.sh#PRODUCTS`),
and the tag has to be the `v<version>` the manifest itself declares, so a URL
for another Glyndor product, or for another tag of this one, is refused by
name. What it still does not bind is `bin` to the downloaded asset, or the
hash to any actual bytes: the cases in `tests/artifacts/check-manifests.test.sh`
record the hand edits the gate accepts.

On the generated path, the renderer constructs URL and executable mapping
from the repository-controlled `PRODUCTS` row and candidate tag, verifies
`SHA256SUMS`, and checks every downloaded digest and its build provenance.
Those controls do not retroactively authenticate a hand-edited JSON file.
The roster itself is trusted configuration; hostile manifest names and
metadata are exercised in `tests/release/render-manifests/render-manifests-products.test.sh`.

### The job

| Threat | Control | Evidence |
|---|---|---|
| The update job stalls (dark cron, rotated key, GitHub outage) and the bucket freezes silently | `freshness-update` fails when the newest successful scheduled run of `update.yml` is older than `max-age-days: 3` (`.github/workflows/freshness.yml#freshness-update`); it runs twice daily and on every push to main (`.github/workflows/freshness.yml#Freshness`), and a second watcher watches it (`.github/workflows/freshness.yml#freshness-itself`) | test: `tests/ci/reusable/reusable-schedule-freshness.test.sh#an 11-day-old run fails the 10-day limit`; `tests/ci/reusable/reusable-schedule-freshness.test.sh#no successful run on record fails`. The caller's inputs are read, not tested |
| A hung run holds the concurrency group | `timeout-minutes: 10` against a measured 13 to 20 seconds (`.github/workflows/update.yml#update`) | none; measurement read off the same job's `timeout-minutes`, 2026-09-02 |
| A checkout persists the job token | `persist-credentials: false` on every checkout | measurement: `grep -c 'actions/checkout@' .github/workflows/*.yml` against `grep -c 'persist-credentials: false' .github/workflows/*.yml`; no test |
| An action receives the app private key | the GitHub-owned `actions/create-github-app-token` in `update.yml`, pinned by full SHA, and it receives the app's private key. Everything else is a local reusable (`./.github/workflows/reusable-*.yml`) or a GitHub-owned action pinned by full SHA (`actions/checkout`, `actions/setup-go`, `actions/cache`). The reusables are copies taken from a named tag and compared daily with the sibling channels (`.github/workflows/drift.yml#drift`, `scripts/monitoring/check-reusable-drift.sh#check-reusable-drift`) | measurement: `grep -n 'uses:' .github/workflows/*.yml`; none as a test. The tooling-isolation assertion in `reusable-workflow-lint.yml` refuses `cargo`, `go`, `gem`, `npm` and unpinned `pip` installs in a job that references `secrets.*`; it also refuses a `uses:` action from any owner other than `actions` or `github` in a job that references `secrets.*`, so the first-party app-token action passes and a third-party one would not |
| A test exists and nothing runs it; a script exists and nothing tests it | `tests/ci/suites/ci-runs-every-test.test.sh` and `scripts/quality/check-test-coverage.sh`, each including itself (`scripts/quality/check-test-coverage.sh#check-test-coverage`) | test: `tests/ci/suites/ci-runs-every-test.test.sh#every test in tests/ is invoked by a workflow`; `tests/ci/suites/ci-runs-every-test.test.sh#this watcher is itself invoked by a workflow` |
| A `run:` block in `update.yml` is edited and no test notices | the suite extracts the workflow's own `run:` blocks and executes them as they ship (`tests/publication/update/update-workflow.test.sh#the render step was extracted from the workflow`, `tests/publication/update/update-workflow.test.sh#the validate step was extracted from the workflow`, `tests/publication/update/update-workflow.test.sh#the commit step was extracted from the workflow`) | test: the three "was extracted from the workflow" cases named above |

## Key rotation

The renderer carries two key slots (`scripts/release/render-manifests.sh#RELEASE_PUBKEY_B64`,
`scripts/release/render-manifests.sh#RELEASE_PUBKEY2_B64`),
and a release verifies if any configured key signed it; an empty slot is not a
key, and exhausting both is an error (`scripts/release/render-manifests.sh#verify_sha256sums`).
The organization's rotation is make-before-break
(`scripts/release/render-manifests.sh#RELEASE_PUBKEY2_B64`):

1. Distribute both public keys in releases still signed with the old key,
   and add the new key to `RELEASE_PUBKEY2_B64` here, in the Homebrew tap's
   renderer and in every product verifier.
2. Wait for consumers to receive both keys before changing the signer.
3. Products switch to signing with the new key. After that transition has
   propagated, move the new key into the first slot and empty the second.

Switching the signer before both keys have propagated breaks verification.
The product is skipped, its manifest remains untouched and the job ends red.
The bucket stays on the last version it could verify; the freshness watcher
reports three days without a successful scheduled update. Nothing unverified
ships, but the channel stops advancing.

Tests: `tests/release/render-manifests.test.sh#a release signed by the second key
still verifies`; `tests/release/render-manifests.test.sh#the first key alone still verifies`;
`tests/release/render-manifests.test.sh#two wrong keys still fail closed`.

## Residual risks

Accepted by the owner; recorded here so they are read as decisions rather than
oversights.

- **A human who merges past a red check.** `dco` and the rest are required,
  and the ruleset gives humans no bypass, so the remaining case is the owner
  changing the ruleset itself. `dco-on-main.yml` reports anything that lands
  unsigned despite that.
- **One maintainer** (`.github/CODEOWNERS#.github/workflows/`). A required check is matched
  by name, so a pull request with Write can replace a caller with a stub that
  emits the name. The mitigation, Code Owner review on `.github/workflows/`,
  waits for the day a second human gets access.
- **The roster is trusted, and its names are checked anyway.** The renderer
  holds a manifest name to lowercase letters, digits, dot, hyphen and
  underscore, starting with a letter or a digit, and refuses anything else
  before it becomes a path: `../outside`, nested paths, leading dashes,
  spaces, quotes, backslashes and Unicode are all refused, and a newline splits
  the roster record and is refused as a missing field. The roster belongs to
  this repository, so the check is defence in depth for the day it has an
  automated source. The same table also decides which repository a manifest's
  URL may name (`scripts/artifacts/check-manifests.sh#check-manifests`), so a
  row that named the wrong repository would move the admission with it; the
  shape of a row is checked, that the product it names is the right one is
  not.
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
grep -n 'RELEASE_PUBKEY' scripts/release/render-manifests.sh             # the two slots
grep -n 'timeout-minutes\|group:\|contents:' .github/workflows/update.yml
grep -c 'persist-credentials: false' .github/workflows/*.yml     # one per checkout
grep -n 'uses:' .github/workflows/*.yml                          # no third-party action
bash scripts/quality/check-doc-anchors.sh                       # every reference above resolves
./tests/release/render-manifests.test.sh                                 # signature, slots, tag, digests
./tests/publication/update/update-workflow.test.sh                                  # the job's own run: blocks
./tests/artifacts/check-manifests.test.sh                                  # what jq refuses
./tests/governance/check-dco-on-main.test.sh                                # detection on main
```

A control is only as real as its red. Delete it from the file the row names,
run the suite, and the case cited must fail for the reason it names. Where a
row says "none", there is nothing to delete; that is the finding.

## Reporting

Report vulnerabilities privately through the repository's Security tab
(`README.md#Glyndor Scoop bucket`, `CONTRIBUTING.md#Security`).
