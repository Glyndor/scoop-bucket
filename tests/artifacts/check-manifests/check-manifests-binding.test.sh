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
	cp "$HERE/scripts/release/render-manifests.sh" "$t/scripts/release/"
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
description-missing|del(.description)|missing required top-level field "description"|s/if has("description") | not then/if false then/;s/elif (\.description | type) != "string" then/elif false then/;s/elif (\.description | length) == 0 then/elif false then/
description-empty|.description = ""|must be a non-empty string|s/elif (\.description | length) == 0 then/elif false then/
bin-other-asset|.architecture["64bit"].bin = [["other-windows-x86_64.exe", "podup"]]|but this architecture downloads|s/elif \$asset != null and \$e\[0\] != \$asset/elif false/
bin-outside-install-dir|.architecture["64bit"].bin = [["../podup-windows-x86_64.exe", "podup"]]|but this architecture downloads|s/elif \$asset != null and \$e\[0\] != \$asset/elif false/
bin-other-alias|.architecture["64bit"].bin = [["podup-windows-x86_64.exe", "other"]]|names the alias|s/elif \$e\[1\] != \$product/elif false/
bin-with-arguments|.architecture["64bit"].bin = [["podup-windows-x86_64.exe", "podup", "--evil"]]|exactly two elements|s/elif (\$e | length) != 2/elif false/
CASES

# --- a value taken from the manifest is printed escaped -----------------------
# A newline in the homepage would otherwise start a line of the CI log of its own.
T="$(mktree newline)"; manifest "$T" podup.json '.homepage = "x\n::error::forged line"'
rc=0; gate "$T" || rc=$?
check "a homepage with a newline is refused" "1" "$rc"
check "and the newline does not start a line of the log" "0" "$(grep -c '^::error::forged line' "$WORK/out")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
