#!/usr/bin/env bash
#
# Record, check, or put in place the manifests under bucket/ by their SHA-256.
#
# WHY THIS EXISTS
#
# .github/workflows/update.yml renders the manifests in one job, validates them
# there, and commits them in a second, which is the only job that ever holds
# the updater app's private key. The render job reads what a product published:
# a signed SHA256SUMS, a signature, release assets and answers from the GitHub
# API. None of that is this repository's own code, and the job that commits
# must not share a workspace with it.
#
# Splitting the jobs only helps if the commit job can tell that the bytes it
# commits are the bytes the render job produced, and not a version something
# rewrote on the way. This script is how it tells. The render job records the
# manifest and hands it on through its job outputs, which no later job can
# change; the commit job compares the files it is about to commit with that
# manifest and refuses any difference. A manifest carried inside the artifact
# would not do: the commit job downloads the artifact and holds the token that
# can upload one, so a copy in there is a copy it could replace.
#
# THE MANIFEST
#
#   One line per regular file under bucket/, at any depth, in bytewise order:
#   the 64 lowercase hex characters of its SHA-256, two spaces, and its path
#   from the root (`bucket/podup.json`). That is the format `sha256sum` prints,
#   so `sha256sum -c` reads the copy the artifact carries.
#
# WHAT IT REFUSES, with exit 1 and a message naming the cause
#
#   - a root with no bucket/, a bucket/ that is a symlink or not a directory;
#   - an entry under bucket/ that is neither a regular file nor a directory
#     (a symlink, a FIFO), because its bytes are not what the manifest records;
#   - a path with a control character or a backslash: a newline would split a
#     record in two, and `sha256sum` escapes a backslash in the name, so a
#     line holding one would not read back as the file it names;
#   - a bucket/ with no file in it, because a manifest of nothing matches any
#     empty tree and an empty bucket must never be committed;
#   - for `check` and `place`, an expected manifest that is missing or empty,
#     and any difference between it and the tree: a changed byte, a file
#     added, a file missing.
#
# A name outside ASCII is allowed. The renderer holds a manifest name to
# lowercase letters, digits, dot, hyphen and underscore, but this script is
# about the bytes that were written, not about what the roster may name, and a
# name it cannot represent is a name it must refuse rather than mangle.
#
# Usage:
#   manifest-digests.sh list  <root>                    print the manifest of <root>/bucket
#   manifest-digests.sh check <root> <manifest>         exit 0 only when <root>/bucket is exactly <manifest>
#   manifest-digests.sh place <from> <root> <manifest>  check <from>, replace <root>/bucket with its copy,
#                                                       and check <root> again

set -euo pipefail

# `sort` orders under the environment's collation, and the manifest has to be
# the same text on every runner that writes or reads it.
export LC_ALL=C

die() {
	echo "::error::$*" >&2
	exit 1
}

# Whether a path carries a byte the manifest cannot carry. A control
# character splits or ends a record, and `sha256sum` escapes a backslash in a
# name, so a line holding one would not read back as the file it names. Every
# other byte is fine, including a byte above ASCII: the manifest is compared
# as text and the digest of the file is the digest of its bytes.
unrepresentable() { # $1=path
	case "$1" in
	*[[:cntrl:]]* | *\\*) return 0 ;;
	esac
	return 1
}

list_manifest() { # $1=root
	local root="$1" odd f sum count=0
	[ ! -L "$root/bucket" ] || die "$root/bucket is a symlink; the manifest covers files the bucket holds itself"
	[ -d "$root/bucket" ] || die "$root/bucket is missing or is not a directory"
	odd="$(cd "$root" && find bucket ! -type f ! -type d -print -quit)"
	[ -z "$odd" ] || die "$root/$odd is neither a regular file nor a directory"
	while IFS= read -r -d '' f; do
		if unrepresentable "$f"; then
			die "refusing a path with a control character or a backslash: $(printf '%q' "$f")"
		fi
		sum="$(sha256sum < "$root/$f")" || die "cannot read $root/$f"
		printf '%s  %s\n' "${sum%% *}" "$f"
		count=$((count + 1))
	done < <(cd "$root" && find bucket -type f -print0 | sort -z)
	[ "$count" -gt 0 ] || die "$root/bucket holds no file; refusing to record an empty bucket"
}

check_manifest() { # $1=root $2=expected manifest
	local root="$1" expected="$2" actual want
	[ -s "$expected" ] || die "the expected manifest $expected is missing or empty"
	want="$(cat "$expected")"
	actual="$(list_manifest "$root")"
	if [ "$actual" != "$want" ]; then
		echo "::error::the files under $root/bucket are not the ones the render job recorded" >&2
		diff <(printf '%s\n' "$want") <(printf '%s\n' "$actual") | sed 's/^/    /' >&2 || true
		exit 1
	fi
	echo "$(printf '%s\n' "$actual" | wc -l | tr -d ' ') file(s) under $root/bucket match the recorded digests"
}

place_manifest() { # $1=from $2=root $3=expected manifest
	local from="$1" root="$2" expected="$3"
	# The source is checked before anything in the root is touched, so a
	# refused artifact leaves the checkout as it was.
	check_manifest "$from" "$expected"
	rm -rf "$root/bucket"
	cp -R "$from/bucket" "$root/bucket"
	# And the copy is checked too: what counts is the tree the next step reads.
	check_manifest "$root" "$expected"
}

case "${1:-}" in
list)
	[ "$#" -eq 2 ] || die "usage: manifest-digests.sh list <root>"
	list_manifest "$2"
	;;
check)
	[ "$#" -eq 3 ] || die "usage: manifest-digests.sh check <root> <manifest>"
	check_manifest "$2" "$3"
	;;
place)
	[ "$#" -eq 4 ] || die "usage: manifest-digests.sh place <from> <root> <manifest>"
	place_manifest "$2" "$3" "$4"
	;;
*)
	die "usage: manifest-digests.sh list|check|place ..."
	;;
esac
