#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/check-published-manifests.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() {
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

mkdir -p "$WORK/bin" "$WORK/stub" "$WORK/root/bucket" "$WORK/tmp"
printf 'current release bytes' > "$WORK/stub/current.bin"
printf 'old release bytes' > "$WORK/stub/old.bin"
printf 'new release bytes' > "$WORK/stub/new.bin"

cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail

output=""
url=""
proto=""
proto_redir=""
max_time=""
max_filesize=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		-o)
			output="$2"
			shift 2
			;;
		--proto)
			proto="$2"
			shift 2
			;;
		--proto-redir)
			proto_redir="$2"
			shift 2
			;;
		--max-time)
			max_time="$2"
			shift 2
			;;
		--max-filesize)
			max_filesize="$2"
			shift 2
			;;
		--connect-timeout)
			shift 2
			;;
		-*)
			shift
			;;
		*)
			url="$1"
			shift
			;;
	esac
done

printf 'proto=%s proto_redir=%s max_time=%s max_filesize=%s\n' \
	"$proto" "$proto_redir" "$max_time" "$max_filesize" >> "$CURL_LOG"

if [[ "$url" == https://* && "$proto" != "=https" ]]; then
	echo "curl: (1) Protocol \"http\" disabled" >&2
	exit 1
fi

case "$url" in
	*/fail-* )
		echo "curl: (22) simulated download failure" >&2
		exit 22
		;;
	*/redirect-http-* )
		if [ "$proto_redir" = "=https" ]; then
			echo "curl: (47) Maximum (2) redirects followed" >&2
			exit 47
		fi
		cp "$STUB_DIR/current.bin" "$output"
		;;
	*/no-file-* )
		exit 0
		;;
	*/oversize-body-* )
		truncate -s 104857601 "$output"
		;;
	*/oversize-* )
		if [ -n "$max_filesize" ]; then
			echo "curl: (63) Maximum file size exceeded" >&2
			exit 63
		fi
		truncate -s 104857601 "$output"
		;;
	*/v2.0.0/* )
		cp "$STUB_DIR/new.bin" "$output"
		;;
	*)
		cp "$STUB_DIR/current.bin" "$output"
		;;
esac
CURL
chmod +x "$WORK/bin/curl"

write_manifest() {
	local path="$1"
	local version="$2"
	local architecture="$3"
	local url="$4"
	local hash="$5"
	cat > "$path" <<JSON
{
  "version": "$version",
  "architecture": {
    "$architecture": {
      "url": "$url",
      "hash": "$hash"
    }
  }
}
JSON
}

current_hash="$(sha256sum "$WORK/stub/current.bin" | awk '{print $1}')"
old_hash="$(sha256sum "$WORK/stub/old.bin" | awk '{print $1}')"
new_hash="$(sha256sum "$WORK/stub/new.bin" | awk '{print $1}')"

run_watcher() {
	: > "$WORK/curl.log"
	set +e
	PATH="$WORK/bin:$PATH" \
		STUB_DIR="$WORK/stub" \
		CURL_LOG="$WORK/curl.log" \
		TMPDIR="$WORK/tmp" \
		RETRY_DELAY_SECONDS=0 \
		bash "$SCRIPT" "$WORK/root" >"$WORK/out" 2>"$WORK/err"
	exit_code=$?
	set -e
}

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/one.exe" "$current_hash"
write_manifest "$WORK/root/bucket/two.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/two.exe" "$current_hash"
write_manifest "$WORK/root/bucket/three.json" "1.0.0" "arm64" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/three-arm64.exe" "$current_hash"

run_watcher
check "matching hashes pass" "0" "$exit_code"
check "the success line counts every manifest and architecture" "1" \
	"$(grep -c 'verified 3 published asset(s) across 3 manifest(s)' "$WORK/out")"
check "a passing run emits no GitHub error annotation" "0" \
	"$(grep -c '::error' "$WORK/err")"
check "every published architecture was downloaded" "3" "$(wc -l < "$WORK/curl.log")"
check "downloads allow only HTTPS" "3" \
	"$(grep -c '^proto==https ' "$WORK/curl.log")"
check "redirects allow only HTTPS" "3" \
	"$(grep -c 'proto_redir==https ' "$WORK/curl.log")"
check "downloads carry a deadline" "3" \
	"$(grep -c 'max_time=120 ' "$WORK/curl.log")"
check "downloads carry a file-size cap" "3" \
	"$(grep -c 'max_filesize=104857600$' "$WORK/curl.log")"
check "the temporary download directory is removed" "0" \
	"$(find "$WORK/tmp" -mindepth 1 -print | wc -l)"

write_manifest "$WORK/root/bucket/one.json" "9.9.9" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/one.exe" "$current_hash"
rm -f "$WORK/root/bucket/two.json" "$WORK/root/bucket/three.json"
run_watcher
check "a URL for another version fails" "1" "$exit_code"
check "the version mismatch emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://example.test/releases/v1.0.0/one.exe" "$current_hash"
rm -f "$WORK/root/bucket/two.json" "$WORK/root/bucket/three.json"
run_watcher
check "a URL outside a Glyndor release fails" "1" "$exit_code"
check "the external URL emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"

python3 - "$WORK/root/bucket/one.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["architecture"]["arm64"] = "not an object"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
run_watcher
check "a malformed architecture fails" "1" "$exit_code"
check "the malformed architecture emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/one.exe" "$current_hash"
python3 - "$WORK/root/bucket/one.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["architecture"]["arm64"] = manifest["architecture"]["64bit"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
run_watcher
check "every architecture in one manifest is checked" "0" "$exit_code"
check "the success line counts both architectures in that manifest" "1" \
	"$(grep -c 'verified 2 published asset(s) across 1 manifest(s)' "$WORK/out")"
check "the multi-architecture run downloaded both assets in that manifest" "2" \
	"$(wc -l < "$WORK/curl.log")"

write_manifest "$WORK/root/bucket/one.json" "2.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v2.0.0/one.exe" "$old_hash"
rm -f "$WORK/root/bucket/two.json" "$WORK/root/bucket/three.json"
run_watcher
check "sabotage: a new version with an old hash fails" "1" "$exit_code"
check "the hash mismatch emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"
check "the mismatch names the expected and actual digests" "1" \
	"$(grep -c "declares digest $old_hash but the downloaded asset has digest $new_hash" "$WORK/err")"

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/fail-one.exe" "$current_hash"
run_watcher
check "a failed download fails" "1" "$exit_code"
check "a failed download is retried a bounded number of times" "3" \
	"$(wc -l < "$WORK/curl.log")"
check "the failed download emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"
check "the failure names the retry count" "1" \
	"$(grep -c 'after 3 attempts' "$WORK/err")"

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/redirect-http-one.exe" "$current_hash"
run_watcher
check "a redirect to HTTP is rejected" "1" "$exit_code"
check "the rejected redirect emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/oversize-one.exe" "$current_hash"
run_watcher
check "an asset over the transfer cap fails" "1" "$exit_code"
check "the oversized asset emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/oversize-body-one.exe" "$current_hash"
run_watcher
check "an oversized body without a declared size fails" "1" "$exit_code"
check "the oversized body is rejected by the local size cap" "1" \
	"$(grep -c 'over the 104857600-byte cap' "$WORK/err")"

write_manifest "$WORK/root/bucket/one.json" "1.0.0" "64bit" \
	"https://github.com/Glyndor/example/releases/download/v1.0.0/no-file-one.exe" "$current_hash"
run_watcher
check "a successful download without a file fails" "1" "$exit_code"
check "the missing file emits a GitHub error annotation" "1" \
	"$(grep -c '::error file=' "$WORK/err")"

rm -f "$WORK/root/bucket/one.json"
run_watcher
check "an empty bucket fails rather than passing vacuously" "1" "$exit_code"
check "the empty bucket emits a GitHub error annotation" "1" \
	"$(grep -c '::error' "$WORK/err")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
