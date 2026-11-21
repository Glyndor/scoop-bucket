#!/usr/bin/env bash
#
# Tests for the part of scripts/artifacts/check-manifests.sh that binds the
# homepage, the description and the bin entry of a manifest to the product it
# publishes. The url has its own suite (check-manifests-identity.test.sh).
#
# The renderer derives all of them from the PRODUCTS row: the homepage is the
# repository's page, the description is the row's, and bin is one pair, the
# file the architecture downloads and the product the shim is called after.
# Each case plants one violation. Then the same case runs against a copy of
# the gate with the one condition that refuses it replaced by `false`, and it
# must pass there, so a refusal is shown to come from that condition and not
# from some other rule.
#
# Requires: jq.
# shellcheck disable=SC2016 # the sabotage patterns name jq variables; they must not expand
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

mktree() { # $1=name -> prints the tree
	local t="$WORK/$1"
	mkdir -p "$t/scripts/artifacts" "$t/scripts/release" "$t/bucket"
	cp "$HERE/scripts/artifacts/check-manifests.sh" "$t/scripts/artifacts/"
	cp "$HERE/scripts/release/render-manifests.sh" "$HERE/scripts/release/products.sh" "$t/scripts/release/"
	echo "$t"
}
manifest() { jq "$3" "$HERE/bucket/podup.json" > "$1/bucket/$2"; }
gate() { "$1/scripts/artifacts/check-manifests.sh" "$1/bucket" >"$WORK/out" 2>&1; }
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

T="$(mktree good)"; manifest "$T" podup.json '.'
rc=0; gate "$T" || rc=$?
check "the committed podup.json is accepted" "0" "$rc"

# label | jq filter over the committed manifest | text the error holds | sed that removes the one condition
while IFS="|" read -r label filter text cut; do
	T="$(mktree "bad-$label")"; manifest "$T" podup.json "$filter"
	rc=0; gate "$T" || rc=$?
	check "$label is refused" "1" "$rc"
	check "and the error names podup.json" "1" "$(said 'podup.json')"
	check "and says $text" "1" "$(said "$text")"

	S="$(mktree "cut-$label")"; manifest "$S" podup.json "$filter"
	sed "$cut" "$HERE/scripts/artifacts/check-manifests.sh" > "$S/scripts/artifacts/check-manifests.sh"
	chmod +x "$S/scripts/artifacts/check-manifests.sh"
	check "the sabotage for $label changed the gate" "1" \
		"$(cmp -s "$HERE/scripts/artifacts/check-manifests.sh" "$S/scripts/artifacts/check-manifests.sh" && echo 0 || echo 1)"
	rc=0; gate "$S" || rc=$?
	check "without its condition, $label passes (the refusal is that condition's)" "0" "$rc"
done <<'CASES'
homepage-other-repo|.homepage = "https://github.com/Glyndor/other-product"|must be exactly|s/elif \.homepage != ("https:\/\/github.com\/" + \$repo)/elif false/
homepage-javascript|.homepage = "javascript:alert(1)"|must be exactly|s/elif \.homepage != ("https:\/\/github.com\/" + \$repo)/elif false/
description-missing|del(.description)|missing required top-level field "description"|s/if has("description") | not then/if false then/;s/elif (\.description | type) != "string" then/elif false then/;s/elif (\.description | length) == 0 then/elif false then/;s/elif \.description != \$description/elif false/
description-empty|.description = ""|must be a non-empty string|s/elif (\.description | length) == 0 then/elif false then/;s/elif \.description != \$description/elif false/
description-other|.description = "Runs things at install time; powershell -enc AAAA"|the description of the PRODUCTS row of this product|s/elif \.description != \$description/elif false/
license-other|.license = "GPL-3.0-only"|the licence the renderer writes|s/elif \.license != \$license/elif false/
asset-not-the-rows|.architecture["64bit"] = {url: ("https://github.com/Glyndor/podup/releases/download/v" + .version + "/evil.exe"), hash: .architecture["64bit"].hash, bin: [["evil.exe", "podup"]]}|the one the PRODUCTS row names for it|s/elif \$asset != \$named/elif false/
asset-of-the-other-architecture|.architecture["64bit"] = {url: ("https://github.com/Glyndor/podup/releases/download/v" + .version + "/podup-windows-arm64.exe"), hash: .architecture["64bit"].hash, bin: [["podup-windows-arm64.exe", "podup"]]}|the one the PRODUCTS row names for it|s/elif \$asset != \$named/elif false/
architecture-without-an-asset|.architecture["32bit"] = .architecture["64bit"]|which names no asset for it|s/elif \$named == "-"/elif false/;s/elif \$asset != \$named/elif false/
bin-other-asset|.architecture["64bit"].bin = [["other-windows-x86_64.exe", "podup"]]|but this architecture downloads|s/elif \$asset != null and \$e\[0\] != \$asset/elif false/
bin-outside-install-dir|.architecture["64bit"].bin = [["../podup-windows-x86_64.exe", "podup"]]|but this architecture downloads|s/elif \$asset != null and \$e\[0\] != \$asset/elif false/
architecture-extra-key|.architecture["64bit"].extra = "x"|has unexpected key(s)|s/^SUB_KEYS=.*/SUB_KEYS='["url","hash","bin","extra"]'/
hash-upper-case|.architecture["64bit"].hash = "A" + .architecture["64bit"].hash[1:]|must match ^[0-9a-f]{64}$ exactly|s/^HASH_RE=.*/HASH_RE='\\A[0-9a-fA-F]{64}\\z'/
bin-other-alias|.architecture["64bit"].bin = [["podup-windows-x86_64.exe", "other"]]|names the alias|s/elif \$e\[1\] != \$product/elif false/
bin-with-arguments|.architecture["64bit"].bin = [["podup-windows-x86_64.exe", "podup", "--evil"]]|exactly two elements|s/elif (\$e | length) != 2/elif false/
CASES

# --- the description is read as bash reads the row ---------------------------
#
# The renderer takes the row from a double-quoted bash string, so \" in the row is a
# quote in the description it writes. The gate reads the row as it is written and
# applies the same reading, or it would refuse the manifest the renderer renders.
ROW_TEXT='Runs \"rootless\" Podman, costs \$0 and \\ays'
WRITTEN='Runs "rootless" Podman, costs $0 and \ays'
plant_row() { # $1=tree
	ROW="$(printf '\t"Glyndor/podup|podup|%s|podup-windows-x86_64.exe|podup-windows-arm64.exe"' "$ROW_TEXT")" \
		awk '/^\t"Glyndor\/podup\|/ { print ENVIRON["ROW"]; next } { print }' \
		"$HERE/scripts/release/render-manifests.sh" > "$1/scripts/release/render-manifests.sh"
}
T="$(mktree escaped)"; plant_row "$T"
check "the escaped row was planted" "1" "$(grep -cF "podup|$ROW_TEXT|" "$T/scripts/release/render-manifests.sh")"
manifest "$T" podup.json ".description = $(jq -Rn --arg d "$WRITTEN" '$d')"
rc=0; gate "$T" || rc=$?
check "a description that is the row as bash reads it is accepted" "0" "$rc"
manifest "$T" podup.json ".description = $(jq -Rn --arg d "$ROW_TEXT" '$d')"
rc=0; gate "$T" || rc=$?
check "the row as it is written, backslashes and all, is refused" "1" "$rc"
check "and the refusal is for the description" "1" "$(said 'the description of the PRODUCTS row of this product')"
S="$(mktree escaped-cut)"; plant_row "$S"
sed "s/| sed -E 's.*)\"\$/| cat)\"/" "$HERE/scripts/artifacts/check-manifests.sh" > "$S/scripts/artifacts/check-manifests.sh"
chmod +x "$S/scripts/artifacts/check-manifests.sh"
check "the sabotage for the reading of the row changed the gate" "1" \
	"$(cmp -s "$HERE/scripts/artifacts/check-manifests.sh" "$S/scripts/artifacts/check-manifests.sh" && echo 0 || echo 1)"
manifest "$S" podup.json ".description = $(jq -Rn --arg d "$WRITTEN" '$d')"
rc=0; gate "$S" || rc=$?
check "without it the description the renderer writes is refused" "1" "$rc"

# --- the licence the gate requires is the one the renderer writes --------------
#
# The gate holds a literal and the renderer writes a literal, and the renderer cannot
# be run here. Each is read from its file, so changing one alone is red.
licence_of_gate() { sed -n "s/^LICENSE='\\([^']*\\)'\$/\\1/p" "$1"; }
licence_of_renderer() { sed -n 's/.*license: "\([^"]*\)".*/\1/p' "$1"; }
check "the gate names the licence the renderer writes" "$(licence_of_renderer "$HERE/scripts/release/render-manifests.sh")" \
	"$(licence_of_gate "$HERE/scripts/artifacts/check-manifests.sh")"
check "and that licence is not empty" "1" "$([ -n "$(licence_of_gate "$HERE/scripts/artifacts/check-manifests.sh")" ] && echo 1 || echo 0)"
sed 's/license: "MIT"/license: "Apache-2.0"/' "$HERE/scripts/release/render-manifests.sh" > "$WORK/renderer-other-licence.sh"
check "a renderer that writes another licence is told apart from the gate" "1" \
	"$([ "$(licence_of_renderer "$WORK/renderer-other-licence.sh")" != "$(licence_of_gate "$HERE/scripts/artifacts/check-manifests.sh")" ] && echo 1 || echo 0)"

# --- a value taken from the manifest is printed escaped -----------------------
# A newline in the homepage would otherwise start a line of the CI log of its own.
T="$(mktree newline)"; manifest "$T" podup.json '.homepage = "x\n::error::forged line"'
rc=0; gate "$T" || rc=$?
check "a homepage with a newline is refused" "1" "$rc"
check "and the newline does not start a line of the log" "0" "$(grep -c '^::error::forged line' "$WORK/out")"

# --- a roster that cannot be read --------------------------------------------
#
# Without the roster no manifest can be bound to its product, so the gate
# refuses before it reads one. It would still fail without that guard, one
# manifest at a time, with the message for a product the roster does not list,
# so each case names the message of the guard and requires the other to be
# absent.
T="$(mktree no-table)"; manifest "$T" podup.json '.'
printf '#!/usr/bin/env bash\n' > "$T/scripts/release/render-manifests.sh"
rc=0; gate "$T" || rc=$?
check "a renderer with no PRODUCTS table is refused" "1" "$rc"
check "and the refusal says the roster is missing" "1" "$(said 'no PRODUCTS roster in')"
check "and no manifest was read against an empty roster" "0" "$(said 'has no row for')"

T="$(mktree no-renderer)"; manifest "$T" podup.json '.'
rm "$T/scripts/release/render-manifests.sh"
rc=0; gate "$T" || rc=$?
check "a tree with no renderer is refused" "1" "$rc"
check "and the refusal says the roster is missing" "1" "$(said 'no PRODUCTS roster in')"
check "and no manifest was read against an empty roster" "0" "$(said 'has no row for')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
