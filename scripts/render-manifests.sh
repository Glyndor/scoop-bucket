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

# Products to publish, one per line: repo|manifest|description|64bit|arm64
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
	python3 - "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$RELEASE_PUBKEY_B64" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
msg = open(sys.argv[1], "rb").read()
sig = open(sys.argv[2], "rb").read()
# The key constant above is stored raw, so restore the two "=" that base64
# decoding needs. Pasting a padded key here yields "====" and fails to decode.
Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[3] + "==")).verify(sig, msg)
print("SHA256SUMS signature verified")
PY
}

# Print the verified SHA-256 of an asset, or fail if it is absent from SHA256SUMS.
hash_of() { # $1=asset
	awk -v a="$1" '$2 == a { print $1; found = 1 } END { if (!found) exit 1 }' \
		"$work/SHA256SUMS"
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
	local repo manifest desc a64 aarm tag version h64 harm base

	IFS='|' read -r repo manifest desc a64 aarm <<<"$entry"

	tag="$(gh release view --repo "$repo" --json tagName --jq .tagName)" || {
		echo "::error::$repo: could not read the latest release"
		return 1
	}
	version="${tag#v}"

	verify_sha256sums "$repo" "$tag" || {
		echo "::error::$repo $tag: SHA256SUMS is missing or does not verify against the org release key"
		return 1
	}

	h64="$(hash_of "$a64")" || {
		echo "::error::$repo $tag: the verified SHA256SUMS does not list $a64"
		return 1
	}
	harm="$(hash_of "$aarm")" || {
		echo "::error::$repo $tag: the verified SHA256SUMS does not list $aarm"
		return 1
	}

	base="https://github.com/$repo/releases/download/$tag"

	# Build with jq so the output is always valid JSON. `bin` renames the arch
	# exe to the tool name, so `scoop install` exposes it simply as `<manifest>`.
	jq -n \
		--arg version "$version" \
		--arg desc "$desc" \
		--arg homepage "https://github.com/$repo" \
		--arg url64 "$base/$a64" --arg h64 "$h64" --arg a64 "$a64" \
		--arg urlarm "$base/$aarm" --arg harm "$harm" --arg aarm "$aarm" \
		--arg manifest "$manifest" \
		'{
			version: $version,
			description: $desc,
			homepage: $homepage,
			# Every product published here is MIT, so this is fixed rather than
			# per-product. Move it into PRODUCTS before adding one that is not.
			license: "MIT",
			architecture: {
				"64bit": { url: $url64, hash: $h64, bin: [[$a64, $manifest]] },
				"arm64": { url: $urlarm, hash: $harm, bin: [[$aarm, $manifest]] }
			}
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
