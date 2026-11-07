#!/usr/bin/env bash
#
# A pull request must not lower the version of a manifest that is already
# committed. The renderer refuses a rollback when it renders, but a hand edit,
# or a render that was hijacked, can write an older version and an older tag
# that agree with each other, and check-manifests.sh accepts the pair because it
# holds a manifest to its roster row, not to what the base branch already says.
#
# Usage: check-version-monotonic.sh <base commit> [bucket directory]
#
# Compares bucket/*.json in the working tree with the same files at the base
# commit, with the SemVer precedence release_order uses in render-manifests.sh:
# pre-release below stable, numeric identifiers below text, build metadata
# ignored. An equal version passes; a product new in the tree passes; a version
# that is not SemVer, in either side, is an error, so the gate cannot be
# bypassed by writing something it cannot order.
set -euo pipefail

base="${1:?usage: check-version-monotonic.sh <base commit> [bucket directory]}"
dir="${2:-bucket}"

python3 -I - "$base" "$dir" <<'PY'
import json, os, re, subprocess, sys

base, directory = sys.argv[1:]
PATTERN = (r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
           r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
           r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def git(*args):
    done = subprocess.run(["git", *args], capture_output=True, text=True)
    if done.returncode != 0:
        fail(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def precedence(version, where):
    match = re.fullmatch(PATTERN, version) if isinstance(version, str) else None
    if not match:
        fail(f"{where}: {version!r} is not a valid SemVer release version")
    major, minor, patch, pre = match.groups()
    identifiers = [] if pre is None else pre.split(".")
    if any(i.isdigit() and len(i) > 1 and i[0] == "0" for i in identifiers):
        fail(f"{where}: invalid numeric pre-release in {version!r}")
    return (int(major), int(minor), int(patch), pre is None,
            tuple((0, int(i)) if i.isdigit() else (1, i) for i in identifiers))


def version_of(text, where):
    try:
        value = json.loads(text)
    except ValueError as error:
        fail(f"{where}: not valid JSON ({error})")
    if not isinstance(value, dict):
        fail(f"{where}: not a JSON object")
    return value.get("version")


git("rev-parse", "--verify", f"{base}^{{commit}}")
# A pathspec is read from the working directory, so a run from a subfolder saw
# no manifest at all and approved every rollback. Everything below is relative
# to the root of the repository.
os.chdir(git("rev-parse", "--show-toplevel").strip())
names = [n for n in git("ls-tree", "-r", "--name-only", base, "--", directory + "/").split("\n")
         if n.endswith(".json")]
if not names:
    fail(f"no manifest under {directory}/ at {base}: nothing was compared, and a gate that compares nothing approves everything")
for name in names:
    try:
        with open(name, encoding="utf-8") as handle:
            current = handle.read()
    except FileNotFoundError:
        continue
    old = precedence(version_of(git("show", f"{base}:{name}"), f"{name} at {base}"), f"{name} at {base}")
    new_version = version_of(current, name)
    if precedence(new_version, name) < old:
        fail(f"{name}: version {new_version} is below the one already committed on the base branch")
print(f"checked {len(names)} committed manifests against {base}: none goes back")
PY
