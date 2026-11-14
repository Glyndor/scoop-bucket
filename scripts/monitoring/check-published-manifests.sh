#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
bucket="$root/bucket"
MAX_ASSET_BYTES=104857600
DOWNLOAD_ATTEMPTS=3
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-2}"

case "$RETRY_DELAY_SECONDS" in
	'' | *[!0-9]*) RETRY_DELAY_SECONDS=2 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

if ! command -v jq >/dev/null 2>&1; then
	echo "::error::jq is required to read the published manifests" >&2
	exit 1
fi

manifests=("$bucket"/*.json)
if [ "${#manifests[@]}" -eq 0 ]; then
	echo "::error::no manifests found under $bucket" >&2
	exit 1
fi

verified=0
failed=0
assets=0

download_asset() {
	local url="$1"
	local destination="$2"
	local error_file="$3"
	local attempt status=1

	for ((attempt = 1; attempt <= DOWNLOAD_ATTEMPTS; attempt++)); do
		rm -f -- "$destination"
		if curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 --max-filesize "$MAX_ASSET_BYTES" -o "$destination" "$url" 2>"$error_file"; then
			return 0
		else
			status=$?
		fi
		if [ "$attempt" -lt "$DOWNLOAD_ATTEMPTS" ]; then
			sleep "$RETRY_DELAY_SECONDS"
		fi
	done

	return "$status"
}

check_asset() {
	local manifest="$1"
	local architecture="$2"
	local url="$3"
	local expected="$4"
	local destination="$5"
	local error_file="$6"
	local size actual

	if ! download_asset "$url" "$destination" "$error_file"; then
		echo "::error file=$manifest::architecture $architecture could not be downloaded after $DOWNLOAD_ATTEMPTS attempts" >&2
		if [ -s "$error_file" ]; then
			sed 's/^/  curl: /' "$error_file" >&2
		fi
		return 2
	fi
	if [ ! -f "$destination" ]; then
		echo "::error file=$manifest::architecture $architecture download reported success without a file" >&2
		return 4
	fi

	size="$(stat -c%s "$destination")"
	if [ "$size" -gt "$MAX_ASSET_BYTES" ]; then
		echo "::error file=$manifest::architecture $architecture is $size bytes, over the $MAX_ASSET_BYTES-byte cap" >&2
		return 3
	fi

	actual="$(sha256sum "$destination")"
	actual="${actual%% *}"
	if [ "$actual" != "$expected" ]; then
		echo "::error file=$manifest::architecture $architecture declares digest $expected but the downloaded asset has digest $actual" >&2
		return 1
	fi

	return 0
}

for manifest in "${manifests[@]}"; do
	if ! jq -e . "$manifest" >/dev/null 2>&1; then
		echo "::error file=$manifest::manifest is not valid JSON" >&2
		failed=$((failed + 1))
		continue
	fi
	if ! jq -e '.architecture | type == "object" and length > 0' "$manifest" >/dev/null 2>&1; then
		echo "::error file=$manifest::manifest declares no architecture" >&2
		failed=$((failed + 1))
		continue
	fi

	manifest_assets=0
	entries="$tmp/entries"
	if ! jq -c '.architecture | to_entries[] | {architecture: .key, url: .value.url, hash: .value.hash}' "$manifest" > "$entries"; then
		echo "::error file=$manifest::manifest architectures could not be read" >&2
		failed=$((failed + 1))
		continue
	fi
	declared_assets="$(jq '.architecture | length' "$manifest")"
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		manifest_assets=$((manifest_assets + 1))
		assets=$((assets + 1))

		architecture="$(jq -r '.architecture' <<<"$entry")"
		url="$(jq -r '.url // empty' <<<"$entry")"
		expected="$(jq -r '.hash // empty' <<<"$entry")"

		if [[ ! "$architecture" =~ ^[A-Za-z0-9_.-]+$ ]]; then
			echo "::error file=$manifest::architecture name is not a plain identifier" >&2
			failed=$((failed + 1))
			continue
		fi
		if [[ "$url" != https://* || "$url" == *$'\n'* || "$url" == *$'\r'* || "$url" == *" "* || "$url" == *$'\t'* ]]; then
			echo "::error file=$manifest::architecture $architecture does not declare an HTTPS URL" >&2
			failed=$((failed + 1))
			continue
		fi
		if [[ ! "$url" =~ ^https://github\.com/Glyndor/[A-Za-z0-9_.-]*[A-Za-z0-9][A-Za-z0-9_.-]*/releases/download/v[0-9A-Za-z]*[A-Za-z0-9][0-9A-Za-z.+-]*/[A-Za-z0-9_.-]*[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
			echo "::error file=$manifest::architecture $architecture does not declare a Glyndor release asset URL" >&2
			failed=$((failed + 1))
			continue
		fi
		version="$(jq -r '.version' "$manifest")"
		if [[ ! "$version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
			echo "::error file=$manifest::manifest version is not a plain version" >&2
			failed=$((failed + 1))
			continue
		fi
		url_version="${url#*/releases/download/v}"
		url_version="${url_version%%/*}"
		if [ "$url_version" != "$version" ]; then
			echo "::error file=$manifest::architecture $architecture URL names version $url_version, not manifest version $version" >&2
			failed=$((failed + 1))
			continue
		fi
		if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
			echo "::error file=$manifest::architecture $architecture does not declare a lowercase SHA-256 digest" >&2
			failed=$((failed + 1))
			continue
		fi

		destination="$tmp/asset-$assets"
		if check_asset "$manifest" "$architecture" "$url" "$expected" "$destination" "$tmp/curl.err"; then
			verified=$((verified + 1))
		else
			failed=$((failed + 1))
		fi
	done < "$entries"

	if [ "$manifest_assets" -ne "$declared_assets" ]; then
		echo "::error file=$manifest::read $manifest_assets of $declared_assets declared architectures" >&2
		failed=$((failed + 1))
	fi
	if [ "$manifest_assets" -eq 0 ]; then
		echo "::error file=$manifest::manifest yielded no architecture to verify" >&2
		failed=$((failed + 1))
	fi
done

if [ "$assets" -eq 0 ] && [ "$failed" -eq 0 ]; then
	echo "::error::no published asset was verified" >&2
	exit 1
fi

if [ "$failed" -ne 0 ]; then
	echo "verified $verified of $assets published asset(s); $failed failure(s)." >&2
	exit 1
fi

echo "verified $verified published asset(s) across ${#manifests[@]} manifest(s)."
