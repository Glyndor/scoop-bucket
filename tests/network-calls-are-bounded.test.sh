#!/usr/bin/env bash
# Every curl invocation under scripts/ carries --max-time.
#
# A fetch with no deadline runs until GitHub's CDN gives up, which can be
# minutes; in the worst case, the runner's own six-hour default. Measured
# against a server that streams 100 bytes per second, `curl -fsSL
# --max-filesize 8M` ran until killed at 8 seconds, and the same call with
# `--max-time 3` returned `curl: (28) Operation timed out after 3001
# milliseconds`. The deadline is the difference between a slow fetch that
# reads as a slow run and a slow fetch that holds the runner.
#
# Comment lines are not invocations: a `# curl -fsSL "..."` line is prose
# about what curl does, and a gate that treated prose as a call would go
# red for an explanatory note in a header.
#
# The test does not check the deadline value, only its presence. The
# drift scripts set `--connect-timeout 10 --max-time 60` on every curl;
# any `--max-time` is sufficient for this gate, and pinning the value
# here would force a change in two unrelated files when one of them
# moves.
#
# Requires: python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# Walk every .sh under <root>/scripts/ and report lines that call curl
# without --max-time. The invocation detector is "the line contains the
# word `curl` followed by whitespace", which rules out the false positives
# a plain `grep curl` would catch: references to a file like `$tmp/curl.err`
# and the literal string `curl:` that the drift scripts prepend to the
# captured curl error.
check_curl() { # $1=scripts root  -> sets rc, prints to stdout/stderr
	python3 - "$1" <<'PY'
import os
import re
import sys

# A line is a curl invocation when (a) it is not a comment line and (b)
# it contains the word `curl` followed by whitespace. The whitespace
# requirement rules out `curl.err` (curl + dot) and `curl:` (curl +
# colon), which appear in the drift scripts' error reporting and would
# otherwise look like invocations to a naive grep.
INVOCATION_RE = re.compile(r"\bcurl\s")


def check_script(path):
	violations = []
	with open(path) as fh:
		for lineno, line in enumerate(fh, 1):
			# Comment-only lines are not invocations, full stop. A trailing
			# comment on a real invocation does not exempt the line, and is
			# not stripped here -- the check is structural.
			if line.lstrip().startswith("#"):
				continue
			if not INVOCATION_RE.search(line):
				continue
			if "--max-time" not in line:
				violations.append((path, lineno, line.rstrip()))
	return violations


root = sys.argv[1]
violations = []
for dirpath, _, filenames in os.walk(f"{root}/scripts"):
	for name in filenames:
		if not name.endswith(".sh"):
			continue
		path = os.path.join(dirpath, name)
		violations.extend(check_script(path))

if violations:
	for path, lineno, line in violations:
		print(
			f"::error file={path}::line {lineno} calls curl without --max-time: {line}"
		)
	sys.exit(1)
print("every curl invocation under scripts/ carries --max-time")
sys.exit(0)
PY
}

# --- the real tree passes -----------------------------------------------

check "the real tree passes" 0 "$(check_curl "$HERE" >/dev/null 2>&1; echo $?)"

# --- a planted violation is caught --------------------------------------

mkdir -p "$WORK/scripts"

# A script that calls curl WITH --max-time is fine.
cat >"$WORK/scripts/good.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL --connect-timeout 10 --max-time 60 "$url" > "$tmp/remote"
SH

# A script that calls curl WITHOUT --max-time must be reported.
cat >"$WORK/scripts/bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL "$url" > "$tmp/remote"
SH

# A script whose only mention of curl is in a comment is fine. The comment
# line is not an invocation, and the script does no fetching of its own.
cat >"$WORK/scripts/with-comment.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# This script used to call curl -fsSL here; the fetch moved out and so
# did the deadline. Kept as an example of how the absence of a call is
# expressed.
true
SH

# A script that mentions curl without calling it (the sed that prepends
# "curl:" to captured errors) is fine.
cat >"$WORK/scripts/with-string.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sed 's/^/  curl: /' "$tmp/curl.err"
SH

out="$(check_curl "$WORK" 2>&1)"; rc=$?
check "a planted violation is caught" 1 "$rc"
check "and names the offending file" 1 \
	"$(printf '%s' "$out" | grep -q 'bad.sh' && echo 1 || echo 0)"
check "and names the line number" 1 \
	"$(printf '%s' "$out" | grep -qE 'bad\.sh:.*line 3' && echo 1 || echo 0)"
check "and does not name a script that has --max-time" 0 \
	"$(printf '%s' "$out" | grep -c 'good.sh')"
check "and does not name the comment-only script" 0 \
	"$(printf '%s' "$out" | grep -c 'with-comment.sh')"
check "and does not name the curl-string-only script" 0 \
	"$(printf '%s' "$out" | grep -c 'with-string.sh')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
