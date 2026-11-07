#!/usr/bin/env bash
#
# Tests for the part of scripts/artifacts/check-manifests.sh that binds a
# manifest's url to the product it publishes (scoop-bucket#274).
#
# The shape of a url says nothing about whose release it is: a url of
# Glyndor/other-product has the same shape as podup's own. The gate takes the
# repository from the PRODUCTS row that names the manifest and the tag from the
# manifest's own version. Each case plants one violation; then the same cases
# run against a copy of the gate with the binding removed, and they must flip,
# so a refusal is shown to come from the binding and not from something else.
#
# Requires: jq.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
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

# A tree to run a gate from: the real gate and the real renderer (whose
# PRODUCTS table is the roster), so the gate resolves its root as it does in CI.
mktree() { # $1=name -> prints the tree
	local t="$WORK/$1"
	mkdir -p "$t/scripts/artifacts" "$t/scripts/release" "$t/bucket"
	cp "$HERE/scripts/artifacts/check-manifests.sh" "$t/scripts/artifacts/"
	cp "$HERE/scripts/release/render-manifests.sh" "$t/scripts/release/"
	echo "$t"
}

manifest() { # $1=tree $2=file name $3=jq filter over the committed podup.json
	jq "$3" "$HERE/bucket/podup.json" > "$1/bucket/$2"
}

gate() { # $1=tree -> rc, output in $WORK/out
	"$1/scripts/artifacts/check-manifests.sh" "$1/bucket" >"$WORK/out" 2>&1
}
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

OTHER_REPO='.architecture["64bit"].url |= sub("/podup/"; "/other-product/")'
OTHER_TAG='.architecture["64bit"].url |= sub("/v[^/]*/"; "/v0.0.1/")'
OTHER_VERSION='.version = "9.9.9"'

# --- the committed manifest is the positive control ---------------------------
T="$(mktree good)"; manifest "$T" podup.json '.'
rc=0; gate "$T" || rc=$?
check "the committed podup.json is accepted" "0" "$rc"

# --- each violation is refused, by name ---------------------------------------
while IFS="|" read -r label filter; do
	T="$(mktree "bad-$label")"; manifest "$T" podup.json "$filter"
	rc=0; gate "$T" || rc=$?
	check "$label is refused" "1" "$rc"
	check "and the error names podup.json" "1" "$(said 'podup.json')"
done <<CASES
other-repo|$OTHER_REPO
other-tag|$OTHER_TAG
other-version|$OTHER_VERSION
CASES

# --- a manifest the roster does not know ---------------------------------------
T="$(mktree unknown)"; manifest "$T" ghost.json '.'
rc=0; gate "$T" || rc=$?
check "a manifest with no PRODUCTS row is refused" "1" "$rc"
check "and the error names the roster" "1" "$(said 'PRODUCTS roster')"

# --- a roster that declares nothing is an error, not a pass -------------------
T="$(mktree empty-roster)"; manifest "$T" podup.json '.'
printf '#!/usr/bin/env bash\n' > "$T/scripts/release/render-manifests.sh"
rc=0; gate "$T" || rc=$?
check "a roster with no products is an error" "1" "$rc"
check "and the error says the url cannot be bound" "1" "$(said 'cannot be bound to its product')"

# --- the control: without the binding the same manifests pass -----------------
# The identity condition is replaced by true in a copy of the gate. If that
# edit did not change the file, the sabotage would be inert and the flip below
# would prove nothing, so the diff is required to be non-empty first.
S="$(mktree sabotaged)"
# shellcheck disable=SC2016 # the pattern names jq variables; they must not expand
sed 's/\$version == "" or \$repo == "" or (\$v.url | startswith(\$base))/true/' \
	"$HERE/scripts/artifacts/check-manifests.sh" > "$S/scripts/artifacts/check-manifests.sh"
chmod +x "$S/scripts/artifacts/check-manifests.sh"
check "the sabotage changed the gate" "1" \
	"$(cmp -s "$HERE/scripts/artifacts/check-manifests.sh" "$S/scripts/artifacts/check-manifests.sh" && echo 0 || echo 1)"
for label in other-repo other-tag other-version; do
	case "$label" in
		other-repo) f="$OTHER_REPO" ;;
		other-tag) f="$OTHER_TAG" ;;
		other-version) f="$OTHER_VERSION" ;;
	esac
	manifest "$S" podup.json "$f"
	rc=0; gate "$S" || rc=$?
	check "without the binding, $label passes (the refusal is the binding's)" "0" "$rc"
done

# --- one definition of a manifest file, shared with check-products-consistent --
# The glob reads bucket/<name>.json only, so a valid manifest copied into a
# subfolder, or named with capitals, was a file the gate never opened.
T="$(mktree subdir)"; manifest "$T" podup.json '.'; mkdir "$T/bucket/sub"; cp "$T/bucket/podup.json" "$T/bucket/sub/podup.json"
rc=0; gate "$T" || rc=$?
check "a valid manifest in a subfolder is refused" "1" "$rc"
check "and the message says where a manifest lives" "1" "$(said 'directly in the bucket')"
T="$(mktree upper)"; manifest "$T" podup.json '.'; cp "$T/bucket/podup.json" "$T/bucket/Podup.JSON"
rc=0; gate "$T" || rc=$?
check "a valid manifest with an upper-case extension is refused" "1" "$rc"
D="$(mktree defsab)"; manifest "$D" podup.json '.'; mkdir "$D/bucket/sub"; cp "$D/bucket/podup.json" "$D/bucket/sub/podup.json"
# shellcheck disable=SC2016 # the pattern names a shell variable; it must not expand
sed 's/^if \[ -n "\$odd" \]; then/if false; then/' "$HERE/scripts/artifacts/check-manifests.sh" > "$D/scripts/artifacts/check-manifests.sh"
check "the definition control changed the gate" "1" \
	"$(cmp -s "$HERE/scripts/artifacts/check-manifests.sh" "$D/scripts/artifacts/check-manifests.sh" && echo 0 || echo 1)"
rc=0; gate "$D" || rc=$?
check "without the definition, the subfolder copy passes" "0" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
