#!/usr/bin/env bash
#
# Shared fixture for the render tests. Sourced, never run: it stands up an
# ephemeral signing key, a stub `gh` that answers `release view`, `release
# download` and `attestation verify` from files on disk, and the helpers that
# publish a synthetic release and drive the generator.
#
# It exists because the cases outgrew one file. tests/render-manifests.test.sh
# passed the 500-line hard limit once build provenance was covered, and
# duplicating the fixture across two files would have left two copies of a
# stub to keep in step, which is the shape that has bitten this organisation
# before.
#
# Not named *.test.sh on purpose: tests/ci-runs-every-test.test.sh requires
# every test file to be invoked by a workflow, and this one is not a test.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$HERE/scripts/render-manifests.sh"
WORK="$(mktemp -d)"
RELEASES="$WORK/releases"
BIN="$WORK/bin"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# --- an ephemeral signing key, and a stub gh that serves fixtures ------------

mkdir -p "$BIN" "$RELEASES"
PUBKEY="$(python3 - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
key = Ed25519PrivateKey.generate()
open(os.path.join(sys.argv[1], "signing.key"), "wb").write(
    key.private_bytes(encoding=serialization.Encoding.Raw,
                      format=serialization.PrivateFormat.Raw,
                      encryption_algorithm=serialization.NoEncryption()))
pub = key.public_key().public_bytes(encoding=serialization.Encoding.Raw,
                                    format=serialization.PublicFormat.Raw)
# Unpadded, the way the generator stores and re-pads it.
print(base64.b64encode(pub).decode().rstrip("="))
PY
)"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"; shift || true
repo=""; dir=""; source_ref=""; signer=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
		--repo) repo="${args[i+1]}" ;;
		--dir)  dir="${args[i+1]}" ;;
		--source-ref) source_ref="${args[i+1]}" ;;
		--signer-workflow) signer="${args[i+1]}" ;;
	esac
done
base="$RELEASES/${repo//\//__}"
case "$sub" in
	release)
		[ -d "$base" ] || { echo "release not found" >&2; exit 1; }
		if [ "${args[0]}" = "view" ]; then
			cat "$base/tag"
		else
			cp "$base/SHA256SUMS" "$dir/SHA256SUMS" 2>/dev/null || exit 1
			cp "$base/SHA256SUMS.sig" "$dir/SHA256SUMS.sig" 2>/dev/null || exit 1
		fi
		;;
	attestation)
		# The renderer calls `gh attestation verify FILE --repo R
		# --source-ref REF --signer-workflow W --format json`. argv
		# after `shift` is: [0]=verify, [1]=FILE, [2]=--repo,
		# [3]=R, [4]=--source-ref, [5]=REF, [6]=--signer-workflow,
		# [7]=W, [8]=--format, [9]=json. The outcome is steered by
		# ATTEST_STUB_OUTCOME; default is a one-entry JSON array
		# from the fixture's attestation.json. Each failure shape
		# prints a message matching one of the three regexes the
		# renderer uses to pick its error branch.
		case "${ATTEST_STUB_OUTCOME:-ok}" in
			ok)
				cat "$base/attestation.json"
				;;
			no-attestation)
				echo "no attestations found for $repo at ${source_ref:-${args[5]}} (HTTP 404)" >&2
				exit 1
				;;
			wrong-tag)
				echo "the attestation source ref does not match expected ${source_ref:-${args[5]}}; the artifact was built from another tag" >&2
				exit 1
				;;
			wrong-signer)
				echo "the signer workflow does not match ${signer:-${args[7]}}; cert-identity check failed" >&2
				exit 1
				;;
			*)
				echo "stub gh: unknown ATTEST_STUB_OUTCOME ${ATTEST_STUB_OUTCOME}" >&2
				exit 90
				;;
		esac
		;;
	*) echo "stub gh: unexpected subcommand $sub" >&2; exit 90 ;;
esac
SH
chmod +x "$BIN/gh"

# Curl stub for the asset download. Parses the URL the same way the
# drift script's curl does -- owner/repo from the host, tag and asset
# from the path -- and serves the matching fixture file. The renderer's
# `verify_attestation` downloads `podup-windows-x86_64.exe` from the
# tagged release; that file lives at
# `$RELEASES/<slug>/asset_<asset>` because publish writes it there
# alongside SHA256SUMS, with the deterministic content `asset-<name>`
# that SHA256SUMS carries the SHA-256 of.
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
		-o)    output="${args[i+1]}" ;;
		http*) url="${args[i]}" ;;
	esac
done
[ -n "$output" ] || { echo "curl stub: no -o output" >&2; exit 1; }
[ -n "$url" ] || { echo "curl stub: no url" >&2; exit 1; }
# https://github.com/owner/repo/releases/download/TAG/ASSET
path="${url#https://github.com/}"
owner_repo="${path%%/releases/download/*}"
rest="${path#*/releases/download/}"
tag="${rest%%/*}"
asset="${rest#*/}"
slug="${owner_repo//\//__}"
fixture="$RELEASES/$slug/asset_${asset}"
if [ ! -f "$fixture" ]; then
	echo "curl stub: no fixture for $url (looked at $fixture)" >&2
	exit 1
fi
cp "$fixture" "$output"
SH
chmod +x "$BIN/curl"

export RELEASES
export PATH="$BIN:$PATH"

publish() { # $1=repo $2=tag $3...=asset names
	local repo="$1" tag="$2"; shift 2
	local base="$RELEASES/${repo//\//__}"
	rm -rf "$base"; mkdir -p "$base"
	printf '%s' "$tag" > "$base/tag"
	: > "$base/SHA256SUMS"
	local asset content digest
	for asset in "$@"; do
		# Deterministic content for every asset, every test: what
		# varies is the asset NAME, not the bytes. Writing the
		# file's real SHA-256 keeps the digest the renderer
		# computes (from the downloaded file) in lockstep with
		# the digest SHA256SUMS declares, so the curl stub can
		# serve the same fixture the manifest fingerprints.
		content="$(printf 'asset-%s' "$asset")"
		printf '%s' "$content" > "$base/asset_${asset}"
		digest="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
		printf '%s  %s\n' "$digest" "$asset" >> "$base/SHA256SUMS"
	done
	python3 - "$WORK/signing.key" "$base/SHA256SUMS" "$base/SHA256SUMS.sig" <<'PY'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[3], "wb").write(key.sign(open(sys.argv[2], "rb").read()))
PY
	# Default attestation: a JSON array with one entry whose certificate
	# matches the tag and signer the renderer expects to verify. Tests
	# that exercise a different attestation outcome steer the gh stub
	# with ATTEST_STUB_OUTCOME rather than mutating this file.
	python3 - "$base/attestation.json" "$repo" "$tag" <<'PY'
import json, sys
out, repo, tag = sys.argv[1], sys.argv[2], sys.argv[3]
expected_ref = f"refs/tags/{tag}"
expected_signer = (
    f"https://github.com/{repo}/.github/workflows/release.yml@{expected_ref}"
)
entry = {
    "verificationResult": {
        "signature": {
            "certificate": {
                "SourceRepository": expected_ref,
                "SubjectAlternativeName": expected_signer,
            },
        },
        "statement": {
            "predicate": {
                "sourceRepositoryRef": expected_ref,
            },
        },
    },
}
json.dump([entry], open(out, "w"))
PY
}

# Re-sign a hand-built SHA256SUMS so the generator still sees a valid signature.
# The point of these cases is malformed CONTENT behind a good signature.
resign() { # $1=sums file $2=repo
	local base="$RELEASES/${2//\//__}"
	cp "$1" "$base/SHA256SUMS"
	python3 - "$WORK/signing.key" "$base/SHA256SUMS" "$base/SHA256SUMS.sig" <<'SIGN'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[3], "wb").write(key.sign(open(sys.argv[2], "rb").read()))
SIGN
}

# A copy of the generator whose PRODUCTS table is replaced wholesale. Replacing
# the block rather than editing fields keeps these tests working when the table
# gains a column, which is what happened to the Homebrew tap's.
generator_with() { # $1=destination $2...=table rows
	local dest="$1"; shift
	local rows
	rows="$(printf '\t"%s"\n' "$@")"
	awk -v rows="$rows" '
		/^PRODUCTS=\(/ { print; print rows; inside = 1; next }
		inside && /^\)/ { print; inside = 0; next }
		!inside        { print }
	' "$GENERATOR" > "$dest"
	chmod +x "$dest"
}

run() { # $1=script $2=repo root
	( cd "$2" && "$1" --pubkey "$PUBKEY" ) > "$WORK/out" 2>&1
}

new_root() { rm -rf "$1"; mkdir -p "$1/scripts" "$1/bucket"; }

# The digests and the product row both files build their tables from. The
# linter cannot see the sourcing files, so it reads these as unused.
# shellcheck disable=SC2034
# SHA256SUMS is exactly what H64 and HARM pin.
H64=$(printf '%s' "asset-podup-windows-x86_64.exe" | sha256sum | awk '{print $1}')
# shellcheck disable=SC2034
HARM=$(printf '%s' "asset-podup-windows-arm64.exe" | sha256sum | awk '{print $1}')

# shellcheck disable=SC2034
PODUP="Glyndor/podup|podup|Docker-compose translator|podup-windows-x86_64.exe|podup-windows-arm64.exe"
