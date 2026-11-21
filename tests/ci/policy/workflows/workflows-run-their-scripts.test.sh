#!/usr/bin/env bash
#
# A workflow step that stops calling its script leaves every suite of that script green and the
# gate it stood for gone: the script's own test never reads the workflow. A mutation audit
# replaced calls with ':' in the sibling repository and nothing failed. This pins, per workflow,
# the scripts it must run, as a line that runs the script and not a comment or an echo that
# names it. Each pinned call is then replaced by ':' in a copy and must be reported, which shows
# the check looks at the call and not only at the file.
#
# A call can also be the right-hand side of an assignment, as the readiness probe of
# freshness.yml is (ready="$(bash ./scripts/...)"): the watcher of published-bytes runs
# only when that value says so, so replacing the call leaves the watcher skipped, and a
# skipped job reports success. The pattern takes that form as well as a bare command.
#
# The mutation catalogue's runner is in this list for the same reason as the
# rest: the weekly sweep is a report, and a report that stops running is a
# report that reads as all clear.
#
# Requires: python3 (standard library only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
PINNED = {
    "dco-on-main.yml": ["scripts/governance/check-dco-on-main.sh"],
    "drift.yml": ["scripts/monitoring/check-channel-drift.sh", "scripts/monitoring/check-render-drift.sh", "scripts/monitoring/check-reusable-drift.sh"],
    "freshness.yml": ["scripts/monitoring/check-schedule-history-ready.sh", "scripts/monitoring/check-suite-on-main.sh", "scripts/monitoring/check-tool-versions.sh"],
    "mutation.yml": ["tests/mutation/run-mutations.sh"],
    "published-bytes.yml": ["scripts/artifacts/check-manifests.sh", "scripts/monitoring/check-published-manifests.sh"],
    "tests.yml": ["scripts/artifacts/check-manifests.sh", "scripts/artifacts/check-products-consistent.sh", "scripts/artifacts/check-version-monotonic.sh"],
    "update.yml": ["scripts/artifacts/check-manifests.sh", "scripts/artifacts/manifest-digests.sh", "scripts/release/render-manifests.sh"],
}
passed = failed = 0


def check(name, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name}: expected {expected!r}, got {actual!r}")


# A command position: the start of the line, optionally after `run:` and `|`, or after a
# variable assigned the output of a command substitution (name="$(...).
CALL = r"^(?:run:\s*)?(?:\|\s*)?(?:[A-Za-z_][A-Za-z0-9_]*=\"\$\()?(?:bash\s+)?"
MUTABLE = r"(?m)^(\s*(?:run:\s*)?(?:[A-Za-z_][A-Za-z0-9_]*=\"\$\()?(?:bash\s+)?)"


def runs(text, script):
    """A line that starts the script as a command, not a comment or an argument of another."""
    pattern = re.compile(CALL + r"\./" + re.escape(script) + r"(?:\s|\)|$)")
    return any(pattern.match(line.strip()) for line in text.splitlines()
               if not line.strip().startswith("#"))


for workflow, scripts in PINNED.items():
    text = (root / ".github/workflows" / workflow).read_text()
    for script in scripts:
        check(f"{workflow} runs {script}", True, runs(text, script))
        # Replace that call, wherever it is made, by ':' and it must be reported.
        mutated = re.sub(MUTABLE + r"\./" + re.escape(script), r"\1:", text)
        check(f"  and is reported when {script} is replaced by :", False, runs(mutated, script))

print(f"{passed} passed, {failed} failed")
print(f"DONE workflows-run-their-scripts.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY

