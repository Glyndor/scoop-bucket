#!/usr/bin/env bash
#
# Print the commit of the manifest the bucket had before the one it has now, so that an update from it can be tried.
#
# Usage: previous-manifest.sh <manifest path>      (run in a checkout with the history of the branch)
#
# Reads `.version` of the manifest at HEAD and walks the commits that changed the file, newest first, until one holds
# a lower version by the order of SemVer (a pre-release is below its release, numeric identifiers are below text
# ones, build metadata is ignored). The same version rendered again is not a previous one, and neither is a commit
# where the file is not JSON or has no version.
#
# Prints "<sha> <version>" and exits 0. Exit 3 when no commit of the history holds a lower version (an update
# cannot be tried, and that is not a pass). Exit 1 for anything else: no such file at HEAD, no readable version, a
# version that is not SemVer, git failing.
set -euo pipefail

file="${1:?usage: previous-manifest.sh <manifest path>}"

python3 -I - "$file" <<'PY'
import json
import re
import subprocess
import sys

file = sys.argv[1]
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def fail(message):
    print(f"::error::previous-manifest: {message}", file=sys.stderr)
    sys.exit(1)


def git(*args):
    done = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode:
        raise OSError(done.stderr.decode("utf-8", "replace").strip() or "git failed")
    return done.stdout.decode("utf-8", "replace")


def version_of(text):
    try:
        value = json.loads(text).get("version")
    except (ValueError, AttributeError):
        return None
    return value if isinstance(value, str) and value else None


def key(version):
    m = SEMVER.fullmatch(version)
    if not m:
        fail(f"{version} is not a SemVer version")
    pre = m.group(4)
    ids = [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")] if pre else []
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), 0 if pre else 1, ids)


try:
    now = version_of(git("show", "HEAD:" + file))
except OSError as e:
    fail(f"{file} cannot be read at HEAD ({e})")
if now is None:
    fail(f"{file} at HEAD is not a manifest with a version, so its version is not known")
current = key(now)
try:
    revisions = git("log", "--format=%H", "--", file).split()
except OSError as e:
    fail(f"the history of {file} cannot be read ({e})")
for sha in revisions:
    try:
        before = version_of(git("show", sha + ":" + file))
    except OSError:
        continue
    if before is not None and key(before) < current:
        print(sha, before)
        sys.exit(0)
print(f"previous-manifest: no commit of the history of {file} holds a version below {now}", file=sys.stderr)
sys.exit(3)
PY
