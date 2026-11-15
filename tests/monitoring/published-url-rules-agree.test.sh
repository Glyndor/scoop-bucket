#!/usr/bin/env bash
#
# The published-bytes watcher and the manifest check each carry a regular expression
# for "a Glyndor release asset url". They were written by hand twice, so one could
# loosen without the other noticing, and the watcher's is the second line of defence.
# This requires the two to be the same expression and to answer the same on a corpus of
# urls, one engine each: bash for the watcher, jq for the check.
#
# Requires: bash, jq, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
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

# The two expressions, as written in the scripts, without their anchors.
bodies="$(python3 -I - "$HERE" <<'PY'
import re, sys
root = sys.argv[1]
watcher = open(root + "/scripts/monitoring/check-published-manifests.sh").read()
checker = open(root + "/scripts/artifacts/check-manifests.sh").read()
w = re.search(r'\[\[ ! "\$url" =~ \^(https://github[^ ]*?)\$ \]\]', watcher)
c = re.search(r"URL_RE='\\Ahttps://(github[^']*?)\\z'", checker)
if not (w and c):
    print("missing"); sys.exit(0)
print(w.group(1).replace("https://", "", 1)); print(c.group(1))
PY
)"
WATCH_BODY="$(sed -n 1p <<<"$bodies")"
CHECK_BODY="$(sed -n 2p <<<"$bodies")"
check "both expressions were found in their scripts" "1" "$([ "$bodies" != missing ] && [ -n "$CHECK_BODY" ] && echo 1 || echo 0)"
check "the watcher and the manifest check use the same expression" "$CHECK_BODY" "$WATCH_BODY"

# One corpus, two engines. The first column is what a Glyndor release asset url is.
corpus=(
	"yes https://github.com/Glyndor/podup/releases/download/v1.2.3/podup-windows-x86_64.exe"
	"yes https://github.com/Glyndor/epistle/releases/download/v0.12.9-rc.1+b5/epistle.zip"
	"no  http://github.com/Glyndor/podup/releases/download/v1.2.3/podup.exe"
	"no  https://github.com/Other/podup/releases/download/v1.2.3/podup.exe"
	"no  https://github.com/Glyndor/../attacker/payload/releases/download/v1/podup.exe"
	"no  https://github.com/Glyndor/podup/releases/download/v1.2.3/../podup.exe"
	"no  https://github.com/Glyndor/podup/releases/download/v1.2.3/podup.exe?token=x"
	"no  https://github.com/Glyndor/podup/releases/download/v1.2.3/podup.exe#frag"
	"no  https://github.com/Glyndor/podup/releases/download/v1.2.3/"
	"no  https://github.com/Glyndor/podup/releases/download/1.2.3/podup.exe"
	"no  https://github.com/Glyndor/podup/releases/latest/download/podup.exe"
	"no  https://github.com/Glyndor/./releases/download/v1/podup.exe"
	"no  https://github.com.evil.example/Glyndor/podup/releases/download/v1/podup.exe"
	"no  https://github.com/Glyndor/podup/releases/download/v1/a/b.exe"
)
WATCH_RE="^https://$WATCH_BODY\$"
for row in "${corpus[@]}"; do
	want="${row%% *}"
	url="${row#* }"; url="${url# }"
	bash_says=no; [[ "$url" =~ $WATCH_RE ]] && bash_says=yes
	jq_says="$(jq -n --arg u "$url" --arg re "\\Ahttps://$CHECK_BODY\\z" '$u | test($re)' | sed 's/true/yes/;s/false/no/')"
	check "watcher: $want for $url" "$want" "$bash_says"
	check "check:   $want for $url" "$want" "$jq_says"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
