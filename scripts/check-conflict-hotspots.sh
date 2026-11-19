#!/bin/sh
# Verifies CONFLICT_HOTSPOTS.md against the fork's actual diff.
#
# UPSTREAM_SYNC.md pillar 2 says "Every upstream file we modify is listed
# there" and "touch a new upstream file -> add an entry in the same PR".
# This script is the CI backstop: it computes the upstream files the fork
# actually modifies since its upstream base commit, and fails loudly if any
# modified upstream file is not listed in CONFLICT_HOTSPOTS.md.
#
# It also gates HACKING.md against the tree: every fork-added file under
# src/apprt/gtk/class/ and src/apprt/gtk/ui/, and every .github/workflows/*.yml
# file, must be named (by file name) in HACKING.md.
#
# Usage: scripts/check-conflict-hotspots.sh [base_commit]
# Exit 0 on success; exit 1 on any hotspot or HACKING.md drift.
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
status=0

if [ -n "$missing" ]; then
	echo "check-conflict-hotspots: $hotspots_file has drifted from the fork's diff against base ${base}." >&2
	echo >&2
	echo "Modified upstream files with NO entry in $hotspots_file:" >&2
	printf '%s\n' "$missing" | sed 's/^/  /' >&2
	echo >&2
	echo "Add entries for these files to $hotspots_file per UPSTREAM_SYNC.md pillar 2." >&2
	status=1
fi

# HACKING.md gate: fork-added GTK class/ui files and all workflow files must
# be named in HACKING.md, so the PR that adds one also documents it.
hacking_file="HACKING.md"
if [ ! -f "$hacking_file" ]; then
	echo "check-conflict-hotspots: $hacking_file not found" >&2
	exit 1
fi

undocumented="$(
	{
		git diff --name-only --diff-filter=A "${base}..HEAD" -- \
			src/apprt/gtk/class src/apprt/gtk/ui
		ls .github/workflows/*.yml
	} | while IFS= read -r f; do
		[ -z "$f" ] && continue
		grep -qF "${f##*/}" "$hacking_file" || printf '%s\n' "$f"
	done
)"

if [ -n "$undocumented" ]; then
	echo "check-conflict-hotspots: $hacking_file does not name these files:" >&2
	printf '%s\n' "$undocumented" | sed 's/^/  /' >&2
	echo >&2
	echo "Add them to the layout table or CI workflow tables in $hacking_file." >&2
	status=1
fi

if [ "$status" -ne 0 ]; then
	exit "$status"
fi

echo "check-conflict-hotspots: all modified upstream files are listed in $hotspots_file; $hacking_file names every fork-added GTK file and workflow."
exit 0
