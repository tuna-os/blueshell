#!/bin/sh
# Verifies CONFLICT_HOTSPOTS.md against the fork's actual diff.
#
# UPSTREAM_SYNC.md pillar 2 says "Every upstream file we modify is listed
# there" and "touch a new upstream file -> add an entry in the same PR".
# This script is the CI backstop: it computes the upstream files the fork
# actually modifies since its upstream base commit, and fails loudly if any
# modified upstream file is not listed in CONFLICT_HOTSPOTS.md.
#
# Usage: scripts/check-conflict-hotspots.sh [base_commit]
# Exit 0 on success; exit 1 if any unlisted upstream file is modified.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

hotspots_file="CONFLICT_HOTSPOTS.md"

if [ ! -f "$hotspots_file" ]; then
	echo "check-conflict-hotspots: $hotspots_file not found" >&2
	exit 1
fi

base=""
if [ -n "${1:-}" ]; then
	base="$1"
elif [ -n "${BASE:-}" ]; then
	base="$BASE"
elif git rev-parse --verify upstream/main >/dev/null 2>&1; then
	base="$(git merge-base HEAD upstream/main)"
elif git rev-parse --verify ghostty/main >/dev/null 2>&1; then
	base="$(git merge-base HEAD ghostty/main)"
else
	first_fork_commit="$(git log --grep='^ptyxis-port: M1+M2' -n 1 --format='%H')"
	if [ -n "$first_fork_commit" ]; then
		base="$(git rev-parse "${first_fork_commit}^")"
	fi
fi

if [ -z "$base" ]; then
	echo "check-conflict-hotspots: cannot determine upstream base commit" >&2
	exit 1
fi

modified_since_base="$(git diff --name-only "${base}..HEAD")"
files_at_base="$(git ls-tree -r --name-only "$base")"

actual="$(
	printf '%s\n' "$modified_since_base" | while IFS= read -r f; do
		[ -z "$f" ] && continue
		printf '%s\n' "$files_at_base" | grep -qxF "$f" && printf '%s\n' "$f"
	done | sort -u
)"

listed="$(
	awk '
		/^## / && / — (HIGH|MEDIUM|LOW) risk$/ {
			sub(/ — (HIGH|MEDIUM|LOW) risk$/, "")
			line = $0
			while (match(line, /`[^`]+`/)) {
				path = substr(line, RSTART + 1, RLENGTH - 2)
				print path
				line = substr(line, RSTART + RLENGTH)
			}
		}
	' "$hotspots_file" | sort -u
)"

missing_file="$(mktemp)"
actual_file="$(mktemp)"
listed_file="$(mktemp)"
trap 'rm -f "$missing_file" "$actual_file" "$listed_file"' EXIT

printf '%s\n' "$actual" >"$actual_file"
printf '%s\n' "$listed" >"$listed_file"

comm -23 "$actual_file" "$listed_file" >"$missing_file"
missing="$(cat "$missing_file")"

if [ -n "$missing" ]; then
	echo "check-conflict-hotspots: $hotspots_file has drifted from the fork's diff against base ${base}." >&2
	echo >&2
	echo "Modified upstream files with NO entry in $hotspots_file:" >&2
	printf '%s\n' "$missing" | sed 's/^/  /' >&2
	echo >&2
	echo "Add entries for these files to $hotspots_file per UPSTREAM_SYNC.md pillar 2." >&2
	exit 1
fi

echo "check-conflict-hotspots: all modified upstream files are listed in $hotspots_file."
exit 0
