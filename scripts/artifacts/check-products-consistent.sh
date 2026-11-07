#!/usr/bin/env bash
#
# scripts/release/render-manifests.sh's PRODUCTS table is the only place a product is
# declared. bucket/ restates it and cannot be generated from the check itself, so
# this compares the two: a product added to PRODUCTS without re-running the
# generator leaves a directory that is a correct artefact of an obsolete input.
# "Generated" says where a file came from, not when.
#
# The README's table is NOT checked, deliberately, and was until 2026-08-26.
#
# It made editing prose break CI. The comparison parsed a markdown table with
# awk, so renaming the heading or adding a column reported every product as
# missing -- which happened while porting this check between the two
# repositories, where one says "Formula" and the other "Manifest". The check was
# wrong and the README was fine.
#
# And it compared two things a person maintains by hand, which anyone can
# reconcile by editing whichever is easier rather than whichever is right. That
# is not a check against ground truth; it is two documents agreeing.
#
# What is lost: the README can drift from what the tap serves. That is a
# documentation staleness, not a correctness failure -- what gets installed is
# decided by bucket/, and that is still checked.
#
# Usage: check-products-consistent.sh [repo-root]   (default: the repo this
# lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Every comparison below is between sorted lists, and `sort` compares under the
# environment's collation. UTF-8 collations ignore punctuation at the primary
# level, so `pod-up` and `podup` -- both legal manifest names -- compare EQUAL
# and `sort -u` drops one. Two lists that genuinely differ then compare the
# same and this exits 0 over real drift. Pin the collation rather than inherit
# whatever the runner happens to have.
export LC_ALL=C

declared="$(awk '/^PRODUCTS=\(/ { inside = 1; next }
                 inside && /^\)/  { exit }
                 inside           { print }' "$root/scripts/release/render-manifests.sh" \
           | sed -n 's/^[^"]*"[^|]*|\([^|]*\)|.*/\1/p' | sort -u)"
[ -n "$declared" ] || {
	echo "::error::could not read PRODUCTS out of scripts/release/render-manifests.sh" >&2
	exit 1
}

# Every entry named like a manifest has to be a regular file, at any depth.
# A directory or a link named like one is not a manifest and a link could point
# anywhere, so it is refused outright rather than skipped: skipping it would let
# an undeclared bucket/evil.json link slip past the roster comparison. A file in
# a subfolder is a manifest Scoop could still install from, whatever the roster
# says; it shows up below as "sub/evil" and disagrees with PRODUCTS. Names are
# matched without regard to case: Scoop runs on Windows, where Evil.JSON is a
# manifest too.
# A symlinked directory is refused whatever its name, since find does not
# descend into it and Scoop would read the manifests behind it.
if [ -L "$root/bucket" ]; then
	echo "::error::bucket/ is a symlink; the bucket must hold its own manifests" >&2
	exit 1
fi
not_regular="$(find "$root/bucket" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) -o \( -type d -iname '*.json' \) \) -printf '%P\n' | sort)"
if [ -n "$not_regular" ]; then
	echo "::error::bucket/ holds a symlink or another entry that is not a regular file or a directory:" >&2
	printf '%s\n' "$not_regular" | sed 's/^/  /' >&2
	exit 1
fi
# The same definition check-manifests.sh holds: a manifest is bucket/<name>.json,
# directly in bucket/, with a lowercase extension. Scoop reads the others too, so
# one is named here instead of being read as some other product.
odd="$(find "$root/bucket" -type f -iname '*.json' -printf '%P\n' | grep -Ev '^[^/]+\.json$' | LC_ALL=C sort || true)"
if [ -n "$odd" ]; then
	echo "::error::bucket/ holds a file that is not bucket/<name>.json (directly in bucket/, lowercase extension):" >&2
	printf '%s\n' "$odd" | sed 's/^/  /' >&2
	exit 1
fi
rendered="$(find "$root/bucket" -type f -iname '*.json' -printf '%P\n' \
           | while read -r f; do echo "${f%.json}"; done | sort -u)"

status=0
if [ "$declared" != "$rendered" ]; then
	echo "::error::bucket/ disagrees with PRODUCTS - re-run scripts/release/render-manifests.sh" >&2
	diff <(echo "$declared") <(echo "$rendered") | sed 's/^/  /' >&2 || true
	status=1
fi
[ "$status" -eq 0 ] && echo "ok  $(echo "$declared" | tr '\n' ' ')"
exit "$status"
