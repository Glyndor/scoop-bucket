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
set -euo pipefail

# The org's Ed25519 release-signing public key (raw, unpadded base64) — the same
# key the products embed; its private half signs SHA256SUMS in every release.
# Verifying against it is what makes the rendered hash trustworthy rather than
# whatever an attacker-influenced release asset happens to contain.
RELEASE_PUBKEY_B64="HFv7vg5FCY7YyKUDbJhaQSfB9SboJGSblJtFbLmLHzM"

# Products to publish, one per line: repo|manifest|description|64bit|arm64
# `64bit`/`arm64` are the Windows release asset names. Add a product here once it
# ships Windows binaries with a signed SHA256SUMS.
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
		--pattern SHA256SUMS --pattern SHA256SUMS.sig --dir "$work" --clobber
	python3 - "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$RELEASE_PUBKEY_B64" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
msg = open(sys.argv[1], "rb").read()
sig = open(sys.argv[2], "rb").read()
Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[3] + "==")).verify(sig, msg)
print("SHA256SUMS signature verified")
PY
}

# Print the verified SHA-256 of an asset, or fail if it is absent from the manifest.
hash_of() { # $1=asset
	awk -v a="$1" '$2 == a { print $1; found = 1 } END { if (!found) exit 1 }' \
		"$work/SHA256SUMS"
}

mkdir -p "$root/bucket"

for entry in "${PRODUCTS[@]}"; do
	IFS='|' read -r repo manifest desc a64 aarm <<<"$entry"

	tag="$(gh release view --repo "$repo" --json tagName --jq .tagName)"
	version="${tag#v}"
	verify_sha256sums "$repo" "$tag"
	h64="$(hash_of "$a64")"
	harm="$(hash_of "$aarm")"
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
			license: "MIT",
			architecture: {
				"64bit": { url: $url64, hash: $h64, bin: [[$a64, $manifest]] },
				"arm64": { url: $urlarm, hash: $harm, bin: [[$aarm, $manifest]] }
			}
		}' >"$root/bucket/$manifest.json"

	echo "rendered bucket/$manifest.json -> $version"
done
