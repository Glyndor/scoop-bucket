#!/usr/bin/env bash
#
# Tests for scripts/render-manifests.sh — the generator that turns a product's
# signed release into the manifest `scoop install` uses.
#
# Why this is worth testing at all: update.yml commits this generator's output
# straight to `main`, so there is no pull request between a bug here and a user
# installing its result. The properties below are the ones that keep that safe —
# the signature gate is fail-closed, one product's broken release cannot remove
# or hold back another's, and the hashes written are the ones the verified
# manifest declared.
#
# Nothing here touches the network. A stub `gh` on PATH serves a synthetic
# release out of a fixture directory, and the release is signed with an
# ephemeral Ed25519 key passed to the generator with --pubkey; the org key stays
# the default for a run with no arguments.
#
# Requires: python3 with cryptography, jq, bash 4+.

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
repo=""; dir=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
		--repo) repo="${args[i+1]}" ;;
		--dir)  dir="${args[i+1]}" ;;
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
	*) echo "stub gh: unexpected subcommand $sub" >&2; exit 90 ;;
esac
SH
chmod +x "$BIN/gh"
export RELEASES
export PATH="$BIN:$PATH"

publish() { # $1=repo $2=tag $3...=asset names
	local repo="$1" tag="$2"; shift 2
	local base="$RELEASES/${repo//\//__}"
	rm -rf "$base"; mkdir -p "$base"
	printf '%s' "$tag" > "$base/tag"
	: > "$base/SHA256SUMS"
	local i=0 asset
	for asset in "$@"; do
		i=$((i + 1))
		printf '%064d  %s\n' "$i" "$asset" >> "$base/SHA256SUMS"
	done
	python3 - "$WORK/signing.key" "$base/SHA256SUMS" "$base/SHA256SUMS.sig" <<'PY'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[3], "wb").write(key.sign(open(sys.argv[2], "rb").read()))
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

PODUP="Glyndor/podup|podup|Docker-compose translator|podup-windows-x86_64.exe|podup-windows-arm64.exe"
H64="0000000000000000000000000000000000000000000000000000000000000001"
HARM="0000000000000000000000000000000000000000000000000000000000000002"

# --- the happy path ---------------------------------------------------------

publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
new_root "$WORK/r1"
generator_with "$WORK/r1/scripts/render-manifests.sh" "$PODUP"
rc=0; run "$WORK/r1/scripts/render-manifests.sh" "$WORK/r1" || rc=$?
check "a verified release renders and exits 0" "0" "$rc"

M="$WORK/r1/bucket/podup.json"
check "the output is valid JSON" "0" "$(jq -e . "$M" >/dev/null 2>&1; echo $?)"
check "the version comes from the release tag" "9.9.9" "$(jq -r .version "$M")"
check "the 64bit url points at the tagged asset" \
	"https://github.com/Glyndor/podup/releases/download/v9.9.9/podup-windows-x86_64.exe" \
	"$(jq -r '.architecture."64bit".url' "$M")"
check "the 64bit hash is the one the signed manifest declares" "$H64" \
	"$(jq -r '.architecture."64bit".hash' "$M")"
check "the arm64 hash is the one the signed manifest declares" "$HARM" \
	"$(jq -r '.architecture.arm64.hash' "$M")"
check "bin renames the arch exe to the tool" "podup-windows-x86_64.exe podup" \
	"$(jq -r '.architecture."64bit".bin[0] | join(" ")' "$M")"
check "the description comes from the table" "Docker-compose translator" \
	"$(jq -r .description "$M")"
check "every field ci.yml requires is present" "true" \
	"$(jq -e '(.version|type=="string") and (.homepage|type=="string")
	          and (.license|type=="string")
	          and (.architecture|to_entries|all(.value.url and .value.hash and (.value.bin|type=="array")))' "$M")"

# --- fail closed ------------------------------------------------------------

publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
printf 'not a signature' > "$RELEASES/Glyndor__podup/SHA256SUMS.sig"
new_root "$WORK/r2"
generator_with "$WORK/r2/scripts/render-manifests.sh" "$PODUP"
rc=0; run "$WORK/r2/scripts/render-manifests.sh" "$WORK/r2" || rc=$?
check "an unverifiable signature skips the product" "3" "$rc"
check "and writes no manifest" "0" "$(find "$WORK/r2/bucket" -name '*.json' | wc -l)"

publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe
new_root "$WORK/r3"
generator_with "$WORK/r3/scripts/render-manifests.sh" "$PODUP"
rc=0; run "$WORK/r3/scripts/render-manifests.sh" "$WORK/r3" || rc=$?
check "an asset missing from the manifest skips the product" "3" "$rc"
check "and writes no manifest" "0" "$(find "$WORK/r3/bucket" -name '*.json' | wc -l)"

new_root "$WORK/r4"
generator_with "$WORK/r4/scripts/render-manifests.sh" \
	"Glyndor/nothing-here|nothing|d|a-x86_64.exe|a-arm64.exe"
rc=0; run "$WORK/r4/scripts/render-manifests.sh" "$WORK/r4" || rc=$?
check "an unreadable release skips the product" "3" "$rc"

# --- one product must not take down another ---------------------------------

publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-arm64.exe
new_root "$WORK/r5"
generator_with "$WORK/r5/scripts/render-manifests.sh" \
	"Glyndor/nothing-here|ghostly|d|a-x86_64.exe|a-arm64.exe" "$PODUP"
printf 'PRE-EXISTING\n' > "$WORK/r5/bucket/ghostly.json"
rc=0; run "$WORK/r5/scripts/render-manifests.sh" "$WORK/r5" || rc=$?
check "a broken product does not stop a good one" "9.9.9" \
	"$(jq -r .version "$WORK/r5/bucket/podup.json")"
check "the run still fails, so the skip is not silent" "3" "$rc"
check "the skipped product keeps the manifest it had" "PRE-EXISTING" \
	"$(cat "$WORK/r5/bucket/ghostly.json")"

# --- pruning ----------------------------------------------------------------

new_root "$WORK/r6"
generator_with "$WORK/r6/scripts/render-manifests.sh" "$PODUP"
printf 'stale\n' > "$WORK/r6/bucket/gone.json"
rc=0; run "$WORK/r6/scripts/render-manifests.sh" "$WORK/r6" || rc=$?
check "pruning a dropped product exits 0" "0" "$rc"
check "the dropped product's manifest is gone" "0" \
	"$(find "$WORK/r6/bucket" -name 'gone.json' | wc -l)"
check "the declared product's manifest stays" "1" \
	"$(find "$WORK/r6/bucket" -name 'podup.json' | wc -l)"

# --- the key is an argument, not an environment variable --------------------

rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-manifests.sh" --pubkey ) >/dev/null 2>&1 || rc=$?
check "--pubkey without a value is a usage error" "2" "$rc"
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-manifests.sh" --wat ) >/dev/null 2>&1 || rc=$?
check "an unknown argument is a usage error" "2" "$rc"
rc=0
( cd "$WORK/r1" && RELEASE_PUBKEY_B64="$PUBKEY" "$WORK/r1/scripts/render-manifests.sh" ) >/dev/null 2>&1 || rc=$?
check "the environment cannot swap the trust anchor" "3" "$rc"

# --- two key slots, so a rotation can be made-before-break ------------------
#
# The org rotation signs with the old key while both are published, and only
# then switches. A renderer with one slot verifies fine through that first
# phase and starts failing when the second lands -- silently, because the
# channel is pull-based and a failed render just stops updating the bucket.

rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-manifests.sh" --pubkey2 ) >/dev/null 2>&1 || rc=$?
check "--pubkey2 without a value is a usage error" "2" "$rc"

# The real release is signed with $PUBKEY. Put it in the SECOND slot behind a
# wrong-but-well-formed first key: the render must still succeed, which is the
# whole point of the second slot.
OTHER="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-manifests.sh" \
	--pubkey "$OTHER" --pubkey2 "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
check "a release signed by the second key still verifies" "0" "$rc"

rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-manifests.sh" --pubkey "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
check "the first key alone still verifies" "0" "$rc"

# Exhausting both slots is an error, not a fallthrough. This is the property
# that must survive: two wrong keys fail exactly as one wrong key did.
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-manifests.sh" \
	--pubkey "$OTHER" --pubkey2 "$OTHER" ) >/dev/null 2>&1 || rc=$?
check "two wrong keys still fail closed" "3" "$rc"

# --- a signed manifest can still be malformed --------------------------------

publish Glyndor/podup v9.9.9 podup-windows-x86_64.exe podup-windows-x86_64.exe podup-windows-arm64.exe
new_root "$WORK/r7"
generator_with "$WORK/r7/scripts/render-manifests.sh" "$PODUP"
rc=0; run "$WORK/r7/scripts/render-manifests.sh" "$WORK/r7" || rc=$?
check "an asset listed twice is rejected" "3" "$rc"
check "and no manifest is written" "0" "$(find "$WORK/r7/bucket" -name '*.json' | wc -l)"
check "the error says how many times" "1" \
	"$(grep -c 'lists podup-windows-x86_64.exe 2 times' "$WORK/out")"

publish Glyndor/podup v9.9.9 podup-windows-arm64.exe
{
	printf 'nothexadecimal!!nothexadecimal!!nothexadecimal!!nothexadecimal!!  podup-windows-x86_64.exe\n'
	cat "$RELEASES/Glyndor__podup/SHA256SUMS"
} > "$WORK/tmpsums"
resign "$WORK/tmpsums" Glyndor/podup
new_root "$WORK/r8"
generator_with "$WORK/r8/scripts/render-manifests.sh" "$PODUP"
rc=0; run "$WORK/r8/scripts/render-manifests.sh" "$WORK/r8" || rc=$?
check "a non-hexadecimal checksum is rejected" "3" "$rc"
check "the error says why" "1" "$(grep -c 'is not hexadecimal' "$WORK/out")"

publish Glyndor/podup v9.9.9 podup-windows-arm64.exe
{
	printf 'abcdef  podup-windows-x86_64.exe\n'
	cat "$RELEASES/Glyndor__podup/SHA256SUMS"
} > "$WORK/tmpsums"
resign "$WORK/tmpsums" Glyndor/podup
new_root "$WORK/r9"
generator_with "$WORK/r9/scripts/render-manifests.sh" "$PODUP"
rc=0; run "$WORK/r9/scripts/render-manifests.sh" "$WORK/r9" || rc=$?
check "a short digest is rejected" "3" "$rc"
check "the error gives the length" "1" "$(grep -c 'is 6 characters, not 64' "$WORK/out")"

# --- two healthy products together -------------------------------------------
# The plain multi-product case: the suite otherwise only ever pairs a good
# product with a broken one, and this is the shape the second real product takes.

publish Glyndor/podup v1.2.3 podup-windows-x86_64.exe podup-windows-arm64.exe
publish Glyndor/other v4.5.6 other-windows-x86_64.exe other-windows-arm64.exe
new_root "$WORK/r10"
generator_with "$WORK/r10/scripts/render-manifests.sh" \
	"Glyndor/podup|podup|first|podup-windows-x86_64.exe|podup-windows-arm64.exe" \
	"Glyndor/other|other|second|other-windows-x86_64.exe|other-windows-arm64.exe"
rc=0; run "$WORK/r10/scripts/render-manifests.sh" "$WORK/r10" || rc=$?
check "two healthy products both render, exit 0" "0" "$rc"
check "both manifests exist" "2" "$(find "$WORK/r10/bucket" -name '*.json' | wc -l)"
check "each gets its own version" "1.2.3" "$(jq -r .version "$WORK/r10/bucket/podup.json")"
check "including the second" "4.5.6" "$(jq -r .version "$WORK/r10/bucket/other.json")"
check "each gets its own description" "second" "$(jq -r .description "$WORK/r10/bucket/other.json")"
check "and its own bin mapping" "other-windows-x86_64.exe other" \
	"$(jq -r '.architecture."64bit".bin[0] | join(" ")' "$WORK/r10/bucket/other.json")"

# --- a product that ships one architecture ----------------------------------
# klyradb publishes a single Windows build; before this, a row had to name both
# assets, so such a product could not be carried at all.

publish Glyndor/single v2.0.0 single-windows-x86_64.exe
new_root "$WORK/r11"
generator_with "$WORK/r11/scripts/render-manifests.sh" \
	"Glyndor/single|single|64bit only|single-windows-x86_64.exe|-"
rc=0; run "$WORK/r11/scripts/render-manifests.sh" "$WORK/r11" || rc=$?
check "a 64bit-only product renders, exit 0" "0" "$rc"
S="$WORK/r11/bucket/single.json"
check "the manifest is valid JSON" "0" "$(jq -e . "$S" >/dev/null 2>&1; echo $?)"
check "it declares exactly one architecture" "1" "$(jq -r '.architecture | length' "$S")"
check "and that one is 64bit" "64bit" "$(jq -r '.architecture | keys[0]' "$S")"
check "with the right url" "https://github.com/Glyndor/single/releases/download/v2.0.0/single-windows-x86_64.exe" \
	"$(jq -r '.architecture."64bit".url' "$S")"
check "it still passes ci.yml's own schema check" "true" \
	"$(jq -e '(.version|type=="string") and (.homepage|type=="string") and (.license|type=="string")
	          and (.architecture|type=="object" and (.|length > 0))
	          and (.architecture|to_entries|all(.value.url and .value.hash and (.value.bin|type=="array")))' "$S")"

publish Glyndor/single v2.0.0 single-windows-arm64.exe
new_root "$WORK/r12"
generator_with "$WORK/r12/scripts/render-manifests.sh" \
	"Glyndor/single|single|arm only|-|single-windows-arm64.exe"
rc=0; run "$WORK/r12/scripts/render-manifests.sh" "$WORK/r12" || rc=$?
check "an arm64-only product renders, exit 0" "0" "$rc"
check "and declares only arm64" "arm64" "$(jq -r '.architecture | keys[0]' "$WORK/r12/bucket/single.json")"

new_root "$WORK/r13"
generator_with "$WORK/r13/scripts/render-manifests.sh" \
	"Glyndor/single|single|neither|-|-"
rc=0; run "$WORK/r13/scripts/render-manifests.sh" "$WORK/r13" || rc=$?
check "a row publishing neither architecture is rejected" "3" "$rc"
check "and says so" "1" "$(grep -c 'publishes neither architecture' "$WORK/out")"

new_root "$WORK/r14"
generator_with "$WORK/r14/scripts/render-manifests.sh" \
	"Glyndor/single|single|empty arm|single-windows-x86_64.exe|"
rc=0; run "$WORK/r14/scripts/render-manifests.sh" "$WORK/r14" || rc=$?
check "an EMPTY field is still an error, not a declaration" "3" "$rc"
check "and names the field" "1" "$(grep -c 'has no aarm' "$WORK/out")"

publish Glyndor/single v2.0.0 single-windows-x86_64.exe
new_root "$WORK/r15"
generator_with "$WORK/r15/scripts/render-manifests.sh" \
	"Glyndor/single|single|arm declared|single-windows-x86_64.exe|single-windows-arm64.exe"
rc=0; run "$WORK/r15/scripts/render-manifests.sh" "$WORK/r15" || rc=$?
check "a DECLARED architecture that is missing still fails" "3" "$rc"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
