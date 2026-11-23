#!/usr/bin/env bash
# Regenerate bucket/*.json from the latest signed release of each Glyndor product.
#
# Pull-based, mirroring Glyndor/apt: no product pushes into this repository. This
# reads each product's public GitHub release, verifies its signed SHA256SUMS
# against the org release-signing key, and renders a Scoop manifest that installs
# the Windows binary with the verified checksum. Windows only: Linux is served
# by the apt repo and macOS by the Homebrew tap.
#
# Run by .github/workflows/update.yml on a schedule and on demand.
#
# With --verify-published it renders nothing: it reads every manifest already in
# bucket/ against the signed SHA256SUMS of the release each url names, and is run by
# .github/workflows/published-bytes.yml.
#
# Exit codes: 0 every product rendered; 3 at least one product was skipped and
# the rest rendered (update.yml commits those, then fails the job); anything
# else is a fatal failure and update.yml must not publish any changes.
set -euo pipefail

# The org's Ed25519 release-signing public key, raw and unpadded base64.
# Verifying against it is what makes the rendered hash trustworthy rather than
# whatever an attacker-influenced release asset happens to contain.
#
# Rotating the org release key means editing this constant here AND in
# Glyndor/homebrew-tap's render-formulae.sh, on top of the products that embed
# it in their own verifiers. A stale value fails closed: every render aborts on
# a signature that no longer matches.
RELEASE_PUBKEY_B64="HFv7vg5FCY7YyKUDbJhaQSfB9SboJGSblJtFbLmLHzM"

# Second slot, empty until a rotation is in flight. The org rotation is
# make-before-break: phase one publishes a release still signed with the old
# key that carries both, consumers pick the new one up, and only then does
# phase two sign with the new key. A renderer with a single slot cannot take
# part in that -- it would verify fine through phase one and start failing the
# moment phase two lands. And because this channel is pull-based, that failure
# is invisible: the render aborts, no manifest is updated, and the bucket
# simply stops moving on the last version it could verify. install.sh and
# install.ps1 have carried two slots for exactly this reason; this brings the
# bucket level with them.
RELEASE_PUBKEY2_B64=""

# The org's ML-DSA-65 release-signing public key, raw and unpadded base64.
# Empty until the organization creates the key: until then no release carries a
# second signature, and every release is admitted exactly as it was before the
# renderer learned to read one.
#
# The second signature is a hybrid, never a replacement. The Ed25519 signature
# is checked first and always; the ML-DSA-65 one is checked when the release
# carries it, and always for a product the required list below names.
RELEASE_PQ_PUBKEY_B64=""

# Second ML-DSA-65 slot, empty until a rotation is in flight, with the same
# make-before-break overlap the Ed25519 slots have: a release signed by either
# configured key verifies.
RELEASE_PQ_PUBKEY2_B64=""

# The products whose ML-DSA-65 signature is required, separated by spaces.
# Empty today.
#
# A second signature that may be left out protects nothing: whoever can forge
# the Ed25519 signature simply does not attach the other one. So a release of
# a product named here is refused without its ML-DSA-65 signature. Every name
# must be a product of the roster below, and one that names no product stops
# the run before any release is read.
#
# The two switches move in one order: a key goes into a slot above first, and
# a product is named here only after a release of it has been verified with
# both signatures. A key with this list empty is the state between the two, and
# is valid; a name here with both slots empty stops the run as well.
RELEASE_PQ_REQUIRED=""

# Bounds on the bytes this script reads off the network. The signature proves
# what the publisher meant, but it does not bound how much of it there is; the
# release assets are attacker-influenced (whoever can publish a release asset
# controls it), and the embedded python reads both files whole, so without a
# cap here an oversized signature or manifest would have every hourly run
# transfer and allocate whatever the publisher attached.
#
# The numbers, derived from what a legitimate file actually looks like:
#
#   MAX_SUMS_BYTES = 4096 (4 KiB). A podup SHA256SUMS lists every asset
#   of the roster, one `<64-hex>  <asset>\n` line each, some five hundred bytes. Even a roster of dozens of
#   products with realistic Windows binary asset names lands well under a
#   kilobyte; 4 KiB is two orders of magnitude of headroom over today's file
#   and still fits comfortably under the size of a single apt sibling's
#   per-signature cap.
#
#   MAX_SIG_BYTES = 64, exact. A raw Ed25519 signature has no other valid
#   length, so any other size is by definition not a signature and is refused
#   the same way whether too large or too small. The check is an equality,
#   not a comparison: anything that is not 64 bytes is wrong here.
#
#   MAX_PQ_SIG_BYTES = 4096. The cap on the second signature's transfer. An
#   ML-DSA-65 signature is exactly 3309 bytes, and the cap sits above it so a
#   sidecar of the wrong length is refused by the length check and not by the
#   transfer, which says what is wrong with it.
#
#   PQ_SIG_LENGTH = 3309, exact. A raw ML-DSA-65 signature (FIPS 204) has no
#   other valid length, so the second signature is held to the same equality
#   as the first one.
#
#   MAX_ASSET_BYTES = 104857600 (100 MiB). The cap on the binary that
#   verify_attestation downloads so its digest can be checked against
#   SHA256SUMS and so the SLSA attestation can be verified against the
#   claimed tag. Today's podup binaries are 5-8 MiB; 100 MiB is over ten
#   times the largest today and leaves room for Electron-class CLI
#   products. Anything larger is suspect as a denial-of-service: the
#   renderer holds the bytes while the attestation check runs.
MAX_SUMS_BYTES=4096
MAX_SIG_BYTES=64
MAX_PQ_SIG_BYTES=4096
PQ_SIG_LENGTH=3309
MAX_ASSET_BYTES=104857600

# The only way to override it is --pubkey, which tests/release/render-manifests.test.sh
# uses to sign a synthetic release with an ephemeral key. A run with no
# arguments trusts the constant above and nothing else, and there is deliberately
# no environment variable that could swap the trust anchor from outside. This is
# the shape Glyndor/apt's verify-debs.sh already uses, where the key is an
# argument for the same reason.
VERIFY_PUBLISHED=0
while [ $# -gt 0 ]; do
	case "$1" in
		--verify-published)
			VERIFY_PUBLISHED=1
			shift
			;;
		--pubkey)
			[ $# -ge 2 ] || { echo "--pubkey needs a value" >&2; exit 2; }
			RELEASE_PUBKEY_B64="$2"
			shift 2
			;;
		--pubkey2)
			[ $# -ge 2 ] || { echo "--pubkey2 needs a value" >&2; exit 2; }
			RELEASE_PUBKEY2_B64="$2"
			shift 2
			;;
		--pq-pubkey)
			[ $# -ge 2 ] || { echo "--pq-pubkey needs a value" >&2; exit 2; }
			RELEASE_PQ_PUBKEY_B64="$2"
			shift 2
			;;
		--pq-pubkey2)
			[ $# -ge 2 ] || { echo "--pq-pubkey2 needs a value" >&2; exit 2; }
			RELEASE_PQ_PUBKEY2_B64="$2"
			shift 2
			;;
		--pq-required)
			[ $# -ge 2 ] || { echo "--pq-required needs a value" >&2; exit 2; }
			RELEASE_PQ_REQUIRED="$2"
			shift 2
			;;
		*)
			echo "unknown argument: $1" >&2
			exit 2
			;;
	esac
done

# The trust constants and the caps are fixed from here on. The release
# signature check sourced below reads them, and nothing after the arguments
# may change what it trusts or how much it reads.
# shellcheck disable=SC2034 # read by scripts/release/release-signature.sh
readonly RELEASE_PUBKEY_B64 RELEASE_PUBKEY2_B64 RELEASE_PQ_PUBKEY_B64 RELEASE_PQ_PUBKEY2_B64 RELEASE_PQ_REQUIRED \
	MAX_SUMS_BYTES MAX_SIG_BYTES MAX_PQ_SIG_BYTES PQ_SIG_LENGTH

# Products to publish, one per line: repo|manifest|description|64bit|arm64
#
# An asset field of "-" means the product publishes nothing for that
# architecture and the manifest omits it; at least one must be a real name. An
# EMPTY field stays an error, because that is what a dropped column looks like.
# `64bit`/`arm64` are the Windows release asset names. Add a product here once it
# ships Windows binaries with a signed SHA256SUMS.
#
# This table is the only place a product is declared. The manifest it renders,
# and the manifests pruned below follow from it. The README's table is prose and
# is not checked against it.
PRODUCTS=(
	"Glyndor/podup|podup|Docker-compose translator and runner for rootless Podman|podup-windows-x86_64.exe|podup-windows-arm64.exe"
)

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The release signature check, verify_sha256sums and
# check_release_configuration, lives in a file of its own that the sibling
# channel carries byte for byte: scripts/monitoring/channel-shared-paths.txt
# lists it, so check-channel-drift compares the whole of it, comments included.
# shellcheck disable=SC1091 # the path is resolved at run time, next to this file
. "$(dirname "${BASH_SOURCE[0]}")/release-signature.sh"

# Verify the build provenance of the release. The signature on SHA256SUMS
# proves the digests the renderer is about to write into formulae; it does
# not prove the digests came from THIS release. An actor who can publish a
# release can take last year's binaries, upload them under a new higher tag
# with the matching old SHA256SUMS and its valid old signature, and the
# renderer accepts them: every digest matches, the signature verifies, and
# the formula points users at old code under a new version number.
# Version monotonicity does not help; the fake tag is higher.
#
# GitHub's SLSA provenance attestations bind an artifact to the tag it was
# built from. A re-uploaded binary still carries the attestation naming its
# OLD tag, so verification against the new tag fails. That is the property
# that closes the gap. Two measured facts decide the shape of this
# function:
#
#   SHA256SUMS itself is NOT attested (`gh attestation verify` on it
#   answers HTTP 404). Only the built artifacts are, so the attested thing
#   has to be an artifact the renderer names.
#
#   `gh attestation verify` takes a file path or an OCI reference. It has
#   no digest-only mode, so the asset has to be downloaded to verify it.
#
# EVERY non-dash asset of a release is verified, not one per release. One
# attested asset binds only its own digest, so an actor who can publish a
# release could replay last year's binaries with the matching old signed
# SHA256SUMS and keep a genuine attestation on whichever asset the renderer did
# not reach. Each asset is downloaded and its SHA-256 computed and checked
# against its SHA256SUMS entry before the attestation check runs, so the digest
# the renderer renders for it is the digest that was verified -- and the control
# inspects something rather than confirming two pieces of input agree without
# having read either.
#
# A release predating attestations is a different fault from a failed
# verification, and the message names which: one is "this release was not
# built by a workflow that emits provenance" and the other is "an
# attestation for this release names a different tag." Both fail closed;
# the operator reading the log needs to know which.
#
# Reads $base from its caller (render_product sets it just above).
verify_attestation() { # $1=repo $2=tag $3=asset $4=expected_sha256
	local repo="$1" tag="$2" asset="$3" expected="$4"
	local asset_path="$work/attest.asset"
	local json_path="$work/attestation.json"
	local err_path="$work/attestation.err"
	local size actual

	rm -f "$asset_path" "$json_path" "$err_path"

	# --connect-timeout and --max-time bound the read: a hung TLS or hung
	# stream is the failure mode that would otherwise outlast the job's
	# own deadline. The network-calls check requires --max-time on every
	# curl. --max-filesize makes curl refuse an asset whose announced size is
	# over the cap before it writes it; the stat below still catches a server
	# that does not announce one.
	if ! curl -fsSL --proto-redir =https --proto =https --connect-timeout 10 --max-time 120 \
		--max-filesize "$MAX_ASSET_BYTES" \
		-o "$asset_path" "$base/$asset"; then
		echo "::error::$repo $tag: failed to download $asset for attestation verification" >&2
		return 1
	fi

	# Bound the bytes on disk BEFORE anything reads them. The cap and
	# its rationale are at MAX_ASSET_BYTES above.
	size="$(stat -c%s "$asset_path")"
	[ "$size" -le "$MAX_ASSET_BYTES" ] || {
		echo "::error::$repo $tag: $asset is $size bytes, over the ${MAX_ASSET_BYTES}-byte cap" >&2
		return 1
	}

	# The digest that gets verified must be the digest that gets rendered.
	# Compute it from the download and compare against the SHA256SUMS
	# entry for this asset before the attestation runs, so a mismatch is
	# a third message and not folded into either of the attestation
	# messages.
	actual="$(sha256sum "$asset_path" | awk '{print $1}')"
	[ "$actual" = "$expected" ] || {
		echo "::error::$repo $tag: downloaded $asset has digest $actual, not the $expected that SHA256SUMS declares" >&2
		return 1
	}

	# --source-ref pins the tag the artifact is claimed to have been
	# built from, --signer-workflow pins the workflow that emitted the
	# attestation. gh enforces them as part of the verify, and exits
	# non-zero when they don't match. The python check below is a sanity
	# pass over the JSON so a successful exit with no entries still
	# fails.
	if ! gh attestation verify "$asset_path" \
		--repo "$repo" \
		--source-ref "refs/tags/$tag" \
		--signer-workflow "$repo/.github/workflows/release.yml" \
		--format json \
		>"$json_path" 2>"$err_path"; then
		# Three failure shapes, distinguished from the gh error text
		# so the operator reading the log knows which fault fired.
		# The first is a release that predates attestations, not an
		# attack; the other two are. All three fail closed.
		local msg
		msg="$(tr '\n' ' ' < "$err_path")"
		if printf '%s' "$msg" | grep -qi 'no attestation\|not found\|404'; then
			echo "::error::$repo $tag: $asset carries no attestation; this release was not built by a workflow that emits provenance, or predates provenance verification" >&2
		elif printf '%s' "$msg" | grep -qi 'signer\|workflow does not match\|cert-identity'; then
			echo "::error::$repo $tag: $asset's attestation was not signed by the release workflow of $repo" >&2
		elif printf '%s' "$msg" | grep -qi 'source ref\|sourcerepositoryref\|different tag'; then
			echo "::error::$repo $tag: $asset's attestation names a different tag; the artifact was built from another tag, not $tag" >&2
		else
			echo "::error::$repo $tag: $asset attestation verification failed: $msg" >&2
		fi
		return 1
	fi

	# A successful verify with no entries in the JSON would mean the CLI
	# returned 0 with nothing to show, which is not a real success. The
	# python block reads the JSON; if gh's output shape changes, this
	# turns into an explicit message instead of a silent pass.
	python3 - "$json_path" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if not isinstance(data, list) or not data:
    sys.exit("attestation verification produced no entries")
PY
}

# Print the verified SHA-256 of an asset. Fails unless the manifest lists it
# exactly once with a well-formed digest.
#
# The signature proves the manifest is the one the product published; it says
# nothing about it being well-formed. Before this, a duplicated entry printed
# BOTH hashes into one field and the run exited 0 -- a fail-open on
# signature-verified input, and in the Scoop bucket's case one that passed
# tests.yml's validation and would have been committed to main. Glyndor/apt's
# publish.yml states the assumption this rests on: the release assets are
# attacker-influenced, because whoever can publish a release controls them.
hash_of() { # $1=asset
	local matches count digest
	# Compared as text. awk compares two fields that look like numbers as numbers,
	# so an asset called 1e5 would match the line of one called 100000.
	matches="$(awk -v a="$1" '$2 "" == a "" { print $1 }' "$work/SHA256SUMS")"
	[ -n "$matches" ] || return 1
	count="$(printf '%s\n' "$matches" | wc -l)"
	[ "$count" -eq 1 ] || {
		echo "::error::the verified SHA256SUMS lists $1 $count times; it must list it exactly once" >&2
		return 1
	}
	digest="$matches"
	case "$digest" in
		*[!0-9a-fA-F]* | "")
			echo "::error::the checksum the verified SHA256SUMS gives for $1 is not hexadecimal" >&2
			return 1
			;;
	esac
	[ "${#digest}" -eq 64 ] || {
		echo "::error::the checksum the verified SHA256SUMS gives for $1 is ${#digest} characters, not 64" >&2
		return 1
	}
	printf '%s\n' "$digest"
}

digest_case_guard() { # $1=repo $2=tag $3=asset $4=digest
	case "$4" in
		*[A-F]*)
			echo "::error::$1 $2: the verified SHA256SUMS has digest $4 for $3 in uppercase; the renderer compares it with the lowercase digest of the download, so it is refused" >&2
			return 1
			;;
	esac
}

# Hold the release tag to a plain version before it is interpolated into
# generated code.
#
# The tag is the only field here that comes from outside this repository and
# carries no signature of its own. SHA256SUMS is verified, and the digests it
# gives are checked to be 64 hex characters before use -- but the tag travels
# beside that signature, not inside it, and it lands in the artifact that is
# published.
#
# A tag carrying a quote, a backslash, a space or any other character outside
# the set below can close the string it is written into and append text that
# runs on every install. Whoever can publish a release in a product repository
# would get code execution on every machine installing from this channel.
#
# So the version is held to the same standard as the digest: a fixed
# character set, checked before it is interpolated. Real tags are v5.1.0,
# v3.7.1 -- digits, dots, and the pre-release and build punctuation semver
# allows. Nothing else.
#
# The two channels must accept and refuse the same tags, so this function is
# compared between them: a tag refused here and published there is a release
# one channel will not serve and the other will.
version_guard() { # $1=repo $2=tag $3=version
	case "$3" in
		"" | *[!0-9A-Za-z.+-]* | .* | *.)
			echo "::error::$1: the release tag \"$2\" is not a plain version; refusing to interpolate it into generated code" >&2
			return 1
			;;
	esac
	case "$3" in
		[0-9]*) ;;
		*)
			echo "::error::$1: the release tag \"$2\" does not start with a digit after stripping a leading v" >&2
			return 1
			;;
	esac
}

# Read the version this repository already serves, from the manifest on disk.
# "-" means nothing is served yet.
#
# This is NOT part of the drift contract: reading the served version out of a
# JSON manifest and out of a Ruby formula are different operations, and only
# the decision they feed is shared.
served_version() { # $1=repo $2=manifest name
	local repo="$1" path="$root/bucket/$2.json" served
	if [ ! -f "$path" ]; then
		printf '%s\n' "-"
		return 0
	fi
	served="$(jq -er '.version | select(type == "string" and length > 0)' "$path")" || {
		echo "::error::$repo: cannot read the served version; refusing to replace the manifest" >&2
		return 1
	}
	printf '%s\n' "$served"
}

# Compare the served version with the candidate using SemVer precedence:
# numeric major/minor/patch; pre-release < stable; numeric pre-release identifiers
# < text (ASCII), compared left to right; build metadata is ignored. rc1 is text.
#
# $1 = the repository, named in the error message
# $2 = the candidate version
# $3 = the product whose served version is compared
#
# The served version is read through served_version, which is the one part of
# this that differs between the channels: a Ruby formula and a JSON manifest
# do not hold it the same way. Everything after that -- the comparison and the
# refusal -- is shared, and the two channels must agree on it, or a release
# refused here is published there.
#
# Prints lower, equal or higher. A candidate below the served version is a
# rollback: a genuinely signed older release marked latest again would move
# the channel backwards, so it is refused unless ALLOW_RELEASE_DOWNGRADE=1,
# which the workflow never sets. Signature, digest and provenance checks stay
# on either way.
#
# The candidate is validated as SemVer before the served version is compared,
# so a first publication of an invalid version is refused with an error that
# names it. Published, it would make the next valid release abort on a served
# version that cannot be parsed.
release_order() { # $1=repo $2=candidate $3=product
	local repo="$1" candidate="$2" served order
	served="$(served_version "$repo" "$3")" || return 1
	order="$(python3 - "$served" "$candidate" "$repo" <<'SEMVER'
import re, sys

served, candidate, repo = sys.argv[1:]
pattern = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"


def precedence(version):
    match = re.fullmatch(pattern, version)
    if not match:
        sys.exit(f"::error::{repo}: {version!r} is not a valid SemVer release version")
    major, minor, patch, pre = match.groups()
    identifiers = [] if pre is None else pre.split(".")
    if any(item.isdigit() and len(item) > 1 and item[0] == "0" for item in identifiers):
        sys.exit(f"::error::{repo}: invalid numeric pre-release in {version!r}")
    return (int(major), int(minor), int(patch), pre is None,
            tuple((0, int(item)) if item.isdigit() else (1, item) for item in identifiers))


new = precedence(candidate)
if served == "-":
    print("higher")
    sys.exit(0)
old = precedence(served)
print("lower" if new < old else "higher" if new > old else "equal")
SEMVER
	)" || return 1
	if [ "$order" = "lower" ]; then
		if [ "${ALLOW_RELEASE_DOWNGRADE:-}" = "1" ]; then
			echo "::warning::$repo: ALLOW_RELEASE_DOWNGRADE=1 permits rollback from served $served to candidate $candidate" >&2
		else
			echo "::error::$repo: refusing release downgrade from served $served to candidate $candidate" >&2
			return 1
		fi
	fi
	printf '%s\n' "$order"
}

# Render one product's manifest. Returns non-zero without touching any file when
# the release cannot be read, its SHA256SUMS does not verify, or an asset the
# table names is missing.
#
# Every step is checked explicitly rather than left to `set -e`: this runs as an
# `if !` condition below, which disables errexit for the whole function, so an
# unchecked failure would carry on and render a manifest from a half-read state.
render_product() { # $1=table entry
	local entry="$1"
	local repo manifest desc a64 aarm tag version h64 harm base arches
	local verify_asset verify_sha target tmp

	IFS='|' read -r repo manifest desc a64 aarm <<<"$entry"

	# Reject a short row by name rather than letting it render from empty
	# variables: an absent asset name would reach hash_of as "", fail there, and
	# report a missing asset when the real fault is a dropped column.
	for field in repo manifest desc a64 aarm; do
		[ -n "${!field}" ] || {
			echo "::error::the PRODUCTS entry \"$entry\" has no $field"
			return 1
		}
	done

	# The manifest name becomes a file name under bucket/ and the shim alias, so
	# it is held to what a manifest name is: lowercase letters, digits, dot, hyphen
	# and underscore, starting with a letter or a digit. A "/" or ".." would write
	# outside bucket/, and whitespace, quotes and backslashes have no place in a
	# file name. The match is made in the C locale: in a UTF-8 one a range such as
	# a-z also matches accented letters. The roster belongs to this repository, so
	# this is defence in depth for the day it has an automated source, not an
	# answer to a known attack.
	printf '%s' "$manifest" | LC_ALL=C grep -qE '^[a-z0-9][a-z0-9._-]*$' || {
		echo "::error::the PRODUCTS entry \"$entry\" has an invalid manifest name \"$manifest\""
		return 1
	}

	# The repository and the two asset names reach the download url. Same
	# reasoning as the manifest name; "-" means nothing published for the slot.
	printf '%s' "$repo" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' || {
		echo "::error::the PRODUCTS entry \"$entry\" has an invalid repository \"$repo\""
		return 1
	}
	case "$repo" in
		Glyndor/*) ;;
		*)
			echo "::error::the PRODUCTS entry \"$entry\" names the repository \"$repo\", which is outside the Glyndor organization"
			return 1
			;;
	esac
	for field in a64 aarm; do
		[ "${!field}" = "-" ] && continue
		printf '%s' "${!field}" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' || {
			echo "::error::the PRODUCTS entry \"$entry\" has an invalid asset name in $field"
			return 1
		}
	done

	tag="$(gh release view --repo "$repo" --json tagName --jq .tagName)" || {
		echo "::error::$repo: could not read the latest release"
		return 1
	}

	case "$tag" in
		v*) ;;
		*)
			echo "::error::$repo: the release tag \"$tag\" does not start with \"v\"; the manifest version is the tag without that prefix and the download URL keeps the whole tag, so a release without it renders a URL check-manifests.sh refuses" >&2
			return 1
			;;
	esac

	version="${tag#v}"

	# The tag is the only field here that comes from outside this repository and
	# carries no signature of its own. SHA256SUMS is verified, and the digests it
	# gives are checked to be 64 hex characters before use -- but the tag travels
	# beside that signature, not inside it, and it lands in a manifest Scoop reads.
	#
	# The JSON here is built with `jq --arg`, which escapes the value properly,
	# so a hostile tag cannot break out of the string the way it can in the tap's
	# unquoted Ruby heredoc. The guard is here anyway: the version reaches Scoop's
	# update comparison and its install paths, the two renderers should not
	# diverge in what they accept, and a validation whose necessity depends on
	# one call site staying `jq` is not a validation.
	#
	# So the version is held to the same standard as the digest: a fixed
	# character set, checked before it is interpolated. Real tags are v5.1.0,
	# v3.7.1 -- digits, dots, and the pre-release and build punctuation semver
	# allows. Nothing else.
	# The guard itself is shared with the sibling channel: the two must
	# accept and refuse the same tags.
	version_guard "$repo" "$tag" "$version" || return 1


	verify_sha256sums "$repo" "$tag" "$manifest" || {
		echo "::error::$repo $tag: SHA256SUMS is missing, oversized, or its signatures did not verify against the org release keys" >&2
		return 1
	}

	if LC_ALL=C grep -q $'\r' "$work/SHA256SUMS"; then
		echo "::error::$repo $tag: the verified SHA256SUMS uses CRLF line endings; every asset name carries a trailing carriage return, so none of them can be matched" >&2
		return 1
	fi

	# "-" means the product publishes nothing for that architecture, so the
	# manifest omits it. An EMPTY field is still rejected above: an empty field
	# between two pipes is what a dropped column looks like, and confusing "not
	# published" with "I mistyped the row" would silently ship half a manifest.
	[ "$a64" != "-" ] || [ "$aarm" != "-" ] || {
		echo "::error::the PRODUCTS entry \"$entry\" publishes neither architecture"
		return 1
	}

	if [ "$a64" != "-" ]; then
		h64="$(hash_of "$a64")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $a64"
			return 1
		}
		digest_case_guard "$repo" "$tag" "$a64" "$h64" || return 1
	fi
	if [ "$aarm" != "-" ]; then
		harm="$(hash_of "$aarm")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $aarm"
			return 1
		}
		digest_case_guard "$repo" "$tag" "$aarm" "$harm" || return 1
	fi

	base="https://github.com/$repo/releases/download/$tag"

	# Verify build provenance for every published digest before anything is
	# rendered. Signing SHA256SUMS authenticates the list's bytes, not the
	# tag each entry was built for; one attested asset binds only its own
	# digest, so every digest the manifest publishes has to be checked
	# against $tag. Checking only one asset would let an actor who can
	# publish a release replay a single architecture's old binary with the
	# matching old signed SHA256SUMS and have the renderer publish the old
	# digest under the newer tag while every other asset still passes.
	# Each non-dash asset gets its own check, and each call compares its
	# download's digest against SHA256SUMS so the digest the renderer
	# renders is the digest that was verified.
	for verify_asset in "$a64" "$aarm"; do
		[ "$verify_asset" != "-" ] || continue
		verify_sha="$(hash_of "$verify_asset")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $verify_asset" >&2
			return 1
		}
		verify_attestation "$repo" "$tag" "$verify_asset" "$verify_sha" || {
			echo "::error::$repo $tag: $verify_asset build provenance is missing, names another tag, or was not signed by the release workflow" >&2
			return 1
		}
	done

	# The candidate is validated even when nothing is served yet: published as
	# is, an invalid first version would make the next valid release abort on a
	# served version that cannot be parsed.
	release_order "$repo" "$version" "$manifest" >/dev/null || exit 1

	# Build the architecture object from only what the product ships, with jq so
	# the result is valid JSON either way.
	arches="$(jq -n '{}')"
	if [ "$a64" != "-" ]; then
		arches="$(jq -n --argjson a "$arches" \
			--arg url "$base/$a64" --arg h "$h64" --arg asset "$a64" --arg tool "$manifest" \
			'$a + {"64bit": {url: $url, hash: $h, bin: [[$asset, $tool]]}}')"
	fi
	if [ "$aarm" != "-" ]; then
		arches="$(jq -n --argjson a "$arches" \
			--arg url "$base/$aarm" --arg h "$harm" --arg asset "$aarm" --arg tool "$manifest" \
			'$a + {"arm64": {url: $url, hash: $h, bin: [[$asset, $tool]]}}')"
	fi

	# A manifest that is a symlink is refused, and the file is written beside it
	# and moved into place. Redirecting straight into the path follows the link,
	# so the render reported success while bucket/ kept only the link, nothing
	# changed for update.yml to commit, and the bucket stayed frozen unnoticed.
	target="$root/bucket/$manifest.json"
	if [ -L "$target" ]; then
		echo "::error::bucket/$manifest.json is a symlink; refusing to write through it" >&2
		return 1
	fi
	tmp="$(mktemp "$root/bucket/.render.XXXXXX")" || return 1

	# Build with jq so the output is always valid JSON. `bin` renames the arch
	# exe to the tool name, so `scoop install` exposes it simply as `<manifest>`.
	jq -n \
		--arg version "$version" \
		--arg desc "$desc" \
		--arg homepage "https://github.com/$repo" \
		--argjson architecture "$arches" \
		'{
			version: $version,
			description: $desc,
			homepage: $homepage,
			# Every product published here is MIT, so this is fixed rather than
			# per-product. Move it into PRODUCTS before adding one that is not.
			license: "MIT",
			architecture: $architecture
		}' >"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	mv -f "$tmp" "$target" || {
		rm -f "$tmp"
		return 1
	}

	echo "rendered bucket/$manifest.json -> $version"
}

# Read what is published instead of rendering it. For every manifest in bucket/ and
# every architecture in it, the release the url names has its SHA256SUMS and signature
# verified exactly as a render verifies them, and the digest in the manifest has to be
# the entry of the asset the url names. A render writes only digests it verified, but
# a manifest is a file a person can edit, and nothing after the render read it against
# the signed list again: the digest of an asset nobody signed (a file added to a
# release by someone who cannot forge the signature) passes every other gate, because
# the bytes behind the url really do have that digest.
#
# A release is verified once per product, however many architectures name it: its
# SHA256SUMS and signatures are three transfers, and a second read of the same
# release learns nothing the first did not. The product is part of the key because
# the verdict depends on it (a product the required list names must carry the second
# signature). The signed list is kept and put back before each digest is read, so
# every architecture is still compared against the list of the release its url
# names, and a release that was refused is refused for every architecture that
# names it.
#
# Exit 0 when every digest is the signed one, 1 otherwise. A bucket with no manifest is
# a failure: nothing was verified.
verify_published() {
	local manifest name repo row row_repo row_name arch url digest prefix rest tag asset signed
	local checked=0 failed=0 key lists=0
	local -A release_list=()
	shopt -s nullglob
	for manifest in "$root"/bucket/*.json; do
		name="$(basename "$manifest" .json)"
		repo=""
		for row in "${PRODUCTS[@]}"; do
			IFS='|' read -r row_repo row_name _ <<<"$row"
			[ "$row_name" != "$name" ] || repo="$row_repo"
		done
		if [ -z "$repo" ]; then
			echo "::error file=$manifest::the PRODUCTS table has no row for \"$name\", so its digests cannot be read against a signed release" >&2
			failed=$((failed + 1))
			continue
		fi
		prefix="https://github.com/$repo/releases/download/"
		while IFS=$'\t' read -r arch url digest; do
			checked=$((checked + 1))
			case "$url" in
				"$prefix"*) rest="${url#"$prefix"}" ;;
				*)
					echo "::error file=$manifest::architecture $arch names $url, which is not an asset of $repo" >&2
					failed=$((failed + 1))
					continue
					;;
			esac
			tag="${rest%%/*}"
			asset="${rest#*/}"
			case "$asset" in
				"" | */*)
					echo "::error file=$manifest::architecture $arch names $url, which is not one asset of one release" >&2
					failed=$((failed + 1))
					continue
					;;
			esac
			key="$repo|$tag|$name"
			if [ -z "${release_list[$key]:-}" ]; then
				if verify_sha256sums "$repo" "$tag" "$name"; then
					lists=$((lists + 1))
					cp "$work/SHA256SUMS" "$work/signed.$lists"
					release_list["$key"]="$work/signed.$lists"
				else
					release_list["$key"]="refused"
				fi
			fi
			if [ "${release_list[$key]}" = refused ]; then
				echo "::error file=$manifest::architecture $arch names $repo $tag, whose release was not admitted" >&2
				failed=$((failed + 1))
				continue
			fi
			cp "${release_list[$key]}" "$work/SHA256SUMS"
			signed="$(hash_of "$asset")" || {
				echo "::error file=$manifest::architecture $arch downloads $asset, which the signed SHA256SUMS of $repo $tag does not list once" >&2
				failed=$((failed + 1))
				continue
			}
			if [ "$signed" != "$digest" ]; then
				echo "::error file=$manifest::architecture $arch declares digest $digest, but the signed SHA256SUMS of $repo $tag gives $signed for $asset" >&2
				failed=$((failed + 1))
			fi
		done < <(jq -r '.architecture // {} | to_entries[] | [.key, (.value.url // ""), (.value.hash // "")] | @tsv' "$manifest")
	done
	if [ "$checked" -eq 0 ]; then
		echo "::error::no digest was read against a signed release" >&2
		return 1
	fi
	if [ "$failed" -ne 0 ]; then
		echo "::error::$failed of $checked published digest(s) are not the ones the signed SHA256SUMS gives" >&2
		return 1
	fi
	echo "verified $checked published digest(s) against the signed SHA256SUMS"
}

# Exit 2 is this repository's convention for a local configuration error, and
# it stops the run before anything is rendered: a broken trust anchor or a
# required product this repository does not publish is not a bad release.
check_release_configuration || exit 2

# One manifest declared twice is rendered twice, the second row over the first, and the
# file that is committed is whichever came last. The roster gate reads the same table
# and refuses it, and the renderer refuses it before it reads a release, by the same
# words.
declare -A seen_manifests=()
for entry in "${PRODUCTS[@]}"; do
	IFS='|' read -r _ manifest _ <<<"$entry"
	if [ -n "${seen_manifests[$manifest]:-}" ]; then
		echo "::error::the PRODUCTS roster declares $manifest twice" >&2
		exit 2
	fi
	seen_manifests["$manifest"]=1
done

if [ "$VERIFY_PUBLISHED" = 1 ]; then
	verify_published
	exit $?
fi

mkdir -p "$root/bucket"

declared=()
skipped=()

for entry in "${PRODUCTS[@]}"; do
	IFS='|' read -r _ manifest _ <<<"$entry"
	declared+=("$manifest")

	# Render each product on its own. Before this, one product's broken release
	# aborted the whole script under `set -e`, so a missing Windows binary, or a
	# signature that stopped verifying, held back every other product's update
	# too. A failure now leaves that product's existing manifest exactly as it is,
	# which still points at its last verified release.
	if ! render_product "$entry"; then
		skipped+=("$manifest")
	fi
done

# Drop manifests for products that are no longer in the table. Keyed on the
# table and not on what rendered this run: a product skipped above must keep the
# manifest it already has, or one bad release would remove it from the bucket.
shopt -s nullglob
for existing in "$root"/bucket/*.json; do
	name="$(basename "$existing" .json)"
	found=""
	for manifest in "${declared[@]}"; do
		[ "$manifest" = "$name" ] && found=1 && break
	done
	[ -n "$found" ] && continue
	rm -f "$existing"
	echo "removed bucket/$name.json (no longer in PRODUCTS)"
done

if [ ${#skipped[@]} -gt 0 ]; then
	echo "::error::skipped ${#skipped[@]} of ${#declared[@]} product(s): ${skipped[*]}"
	exit 3
fi
