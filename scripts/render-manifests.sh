#!/usr/bin/env bash
# Regenerate bucket/*.json from the latest signed release of each Glyndor product.
#
# Pull-based, mirroring Glyndor/apt: no product pushes into this repository. This
# reads each product's public GitHub release, verifies its signed SHA256SUMS
# against the org release-signing key, and renders a Scoop manifest that installs
# the Windows binary with the verified checksum. Windows only — Linux is served
# by the apt repo and macOS by the Homebrew tap.
#
# Run by .github/workflows/update.yml on a schedule and on demand.
#
# Exit codes: 0 every product rendered; 3 at least one product was skipped and
# the rest rendered (update.yml commits those, then fails the job); anything
# else is a failure before any product was reached.
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

# The only way to override it is --pubkey, which tests/render-manifests.test.sh
# uses to sign a synthetic release with an ephemeral key. A run with no
# arguments trusts the constant above and nothing else — there is deliberately
# no environment variable that could swap the trust anchor from outside. This is
# the shape Glyndor/apt's verify-debs.sh already uses, where the key is an
# argument for the same reason.
while [ $# -gt 0 ]; do
	case "$1" in
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
		*)
			echo "unknown argument: $1" >&2
			exit 2
			;;
	esac
done

# Products to publish, one per line: repo|manifest|description|64bit|arm64
#
# An asset field of "-" means the product publishes nothing for that
# architecture and the manifest omits it; at least one must be a real name. An
# EMPTY field stays an error, because that is what a dropped column looks like.
# `64bit`/`arm64` are the Windows release asset names. Add a product here once it
# ships Windows binaries with a signed SHA256SUMS.
#
# This table is the only place a product is declared. The manifest it renders,
# the manifests pruned below, and the README's "Available manifests" table
# (which ci.yml checks against this list) all follow from it.
PRODUCTS=(
	"Glyndor/podup|podup|Docker-compose translator and runner for rootless Podman|podup-windows-x86_64.exe|podup-windows-arm64.exe"
)

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Download a release's SHA256SUMS(+.sig) and verify the signature, failing closed.
verify_sha256sums() { # $1=repo $2=tag
	rm -f "$work/SHA256SUMS" "$work/SHA256SUMS.sig"
	gh release download "$2" --repo "$1" \
		--pattern SHA256SUMS --pattern SHA256SUMS.sig --dir "$work" --clobber \
		|| return 1
	python3 - "$work/SHA256SUMS" "$work/SHA256SUMS.sig" \
		"$RELEASE_PUBKEY_B64" "$RELEASE_PUBKEY2_B64" <<'PY'
import base64, binascii, sys
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

msg = open(sys.argv[1], "rb").read()
sig = open(sys.argv[2], "rb").read()

# Any configured key may be the one that signed this release; an empty slot is
# not a key. Still fails closed -- exhausting the slots is an error, not a
# fallthrough, so a stale pair aborts the render exactly as a single stale key
# did before.
#
# Padding is normalised to a 4-character boundary rather than restored by
# appending two "=", so a key pasted with its padding already on works instead
# of decoding to nothing. Appending blindly was survivable only because the
# error was swallowed below.


def load(b64):
    # validate=True matters: without it b64decode DISCARDS characters outside
    # the alphabet, so "AAAA!!!!BBBB" decodes to six bytes without complaint and
    # a corrupted key silently becomes a shorter one.
    b64 += "=" * (-len(b64) % 4)
    raw = base64.b64decode(b64, validate=True)
    if len(raw) != 32:
        raise ValueError(f"{len(raw)} bytes, not a 32-byte Ed25519 key")
    return Ed25519PublicKey.from_public_bytes(raw)


raw_keys = [k for k in sys.argv[3:] if k]
if not raw_keys:
    sys.exit("no release key configured")

# Loading is separate from verifying so that a broken trust anchor of ours is
# not reported as a bad signature of theirs. `except Exception` around the
# verify call collapsed both into one message, and the operator then went
# looking at the upstream release for a fault that was in this repository.
try:
    keys = [load(k) for k in raw_keys]
except (ValueError, binascii.Error) as exc:
    sys.exit(f"malformed release public key: {exc}")

for key in keys:
    try:
        key.verify(sig, msg)
    except InvalidSignature:
        continue
    print("SHA256SUMS signature verified")
    sys.exit(0)
sys.exit("SHA256SUMS does not verify against any configured release key")
PY
}

# Print the verified SHA-256 of an asset. Fails unless the manifest lists it
# exactly once with a well-formed digest.
#
# The signature proves the manifest is the one the product published; it says
# nothing about it being well-formed. Before this, a duplicated entry printed
# BOTH hashes into one field and the run exited 0 -- a fail-open on
# signature-verified input, and in the Scoop bucket's case one that passed
# ci.yml's validation and would have been committed to main. Glyndor/apt's
# publish.yml states the assumption this rests on: the release assets are
# attacker-influenced, because whoever can publish a release controls them.
hash_of() { # $1=asset
	local matches count digest
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
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

	tag="$(gh release view --repo "$repo" --json tagName --jq .tagName)" || {
		echo "::error::$repo: could not read the latest release"
		return 1
	}
	version="${tag#v}"

	verify_sha256sums "$repo" "$tag" || {
		echo "::error::$repo $tag: SHA256SUMS is missing or does not verify against the org release key"
		return 1
	}

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
	fi
	if [ "$aarm" != "-" ]; then
		harm="$(hash_of "$aarm")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $aarm"
			return 1
		}
	fi

	base="https://github.com/$repo/releases/download/$tag"

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
		}' >"$root/bucket/$manifest.json" || return 1

	echo "rendered bucket/$manifest.json -> $version"
}

mkdir -p "$root/bucket"

declared=()
skipped=()

for entry in "${PRODUCTS[@]}"; do
	IFS='|' read -r _ manifest _ <<<"$entry"
	declared+=("$manifest")

	# Render each product on its own. Before this, one product's broken release
	# aborted the whole script under `set -e`, so a missing Windows binary — or a
	# signature that stopped verifying — held back every other product's update
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
