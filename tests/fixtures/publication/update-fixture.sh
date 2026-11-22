#!/usr/bin/env bash
#
# What the suites of tests/publication/update/ share: the workflow under test,
# a scratch directory, the step extractor, and a sandbox repository the
# extracted steps run in.
#
# The `run:` blocks are extracted from .github/workflows/update.yml and executed
# as they ship, rather than copied into a test. A copy would pass while the
# workflow rots.
#
# Sourced, not run. It sets `-euo pipefail`, WORKFLOW, WORK, the helpers below,
# and removes WORK when the sourcing suite exits. The suite keeps its own
# `pass` and `fail` counters.
#
# Requires: python3, git.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$HERE/.github/workflows/update.yml"
WORK="$(mktemp -d)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

# The shell of a step of update.yml, read as it ships.
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/ci/step-script.sh"
# The suites of update.yml name a step of that one workflow.
step_script() { step_script_of "$WORKFLOW" "$1"; }

# A repository the step can run in: a git repo with a committed bucket/ and a
# stub generator whose behaviour each case chooses. `valid` writes a manifest
# the gate accepts; `yes` writes one it refuses, which is the point of it.
sandbox() { # $1=path $2=code $3=writes? (yes|valid|no|empty|new|del|del-multi)
	local dir="$1" code="$2" mode="$3"
	rm -rf "$dir"; mkdir -p "$dir/scripts" "$dir/scripts/artifacts" "$dir/scripts/release" "$dir/bucket"
	printf '{"version":"1"}\n' > "$dir/bucket/podup.json"
	# del-multi starts with a second tracked manifest so a deletion can leave
	# the channel with one left, which exercises the deletion-only path
	# without also tripping the empty-bucket refusal.
	if [ "$mode" = "del-multi" ]; then
		printf '{"version":"1"}\n' > "$dir/bucket/zzz.json"
	fi
	cat > "$dir/scripts/release/render-manifests.sh" <<SH
#!/usr/bin/env bash
# The roster check-manifests.sh binds each manifest url to (it reads this table).
PRODUCTS=(
	"Glyndor/podup|podup|stub|podup-windows-x86_64.exe"
)
case "$mode" in
	yes)       printf '{"version":"2"}\n' > "$dir/bucket/podup.json" ;;
	valid)     cat > "$dir/bucket/podup.json" <<'JSON'
{
  "version": "1.0.0",
  "description": "stub",
  "homepage": "https://github.com/Glyndor/podup",
  "license": "MIT",
  "architecture": {
    "64bit": {
      "url": "https://github.com/Glyndor/podup/releases/download/v1.0.0/podup-windows-x86_64.exe",
      "hash": "0000000000000000000000000000000000000000000000000000000000000000",
      "bin": [["podup-windows-x86_64.exe", "podup"]]
    }
  }
}
JSON
	           ;;
	empty)     rm -f "$dir"/bucket/*.json ;;
	new)       printf '{"version":"1"}\n' > "$dir/bucket/newproduct.json" ;;
	del)       rm -f "$dir/bucket/podup.json" ;;
	del-multi) rm -f "$dir/bucket/podup.json" ;;
esac
exit $code
SH
	chmod +x "$dir/scripts/release/render-manifests.sh"
	# The validate step calls scripts/artifacts/check-manifests.sh rather than carrying a
	# copy of the jq filter, and the commit job puts the rendered files in place
	# with scripts/artifacts/manifest-digests.sh, so the sandbox needs the real
	# scripts. Copying them is the point: the steps are exercised with the code
	# that ships, and a workflow that stopped calling one would fail here rather
	# than pass on a stub that happens to agree.
	cp "$HERE/scripts/artifacts/check-manifests.sh" "$HERE/scripts/artifacts/manifest-digests.sh" \
		"$dir/scripts/artifacts/"
	chmod +x "$dir/scripts/artifacts/check-manifests.sh" "$dir/scripts/artifacts/manifest-digests.sh"
	# check-manifests.sh reads the roster through the shared table reader.
	cp "$HERE/scripts/release/products.sh" "$dir/scripts/release/"
	git -C "$dir" init -q
	git -C "$dir" -c user.email=t@t -c user.name=t add -A
	git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init
}

run_step() { # $1=script $2=dir ; sets GITHUB_OUTPUT, returns the step's status
	: > "$WORK/gh-output"
	( cd "$2" && GITHUB_OUTPUT="$WORK/gh-output" bash "$1" ) > "$WORK/out" 2>&1
}

# The value of an output: everything after the first `=` of its line. A value
# can hold `=` (the digests are base64, which pads with it), so splitting on
# every `=` would cut one short.
output() { # $1=key
	awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$WORK/gh-output"
}

RENDER="$WORK/render.sh"
VALIDATE="$WORK/validate.sh"
COMMIT="$WORK/commit.sh"
step_script "Render manifests" > "$RENDER"
step_script "Validate the re-rendered manifests" > "$VALIDATE"
step_script "Commit the update to main" > "$COMMIT"
