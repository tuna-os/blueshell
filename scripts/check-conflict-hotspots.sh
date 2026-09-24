#!/bin/sh
# Verifies CONFLICT_HOTSPOTS.md against the fork's actual diff.
#
# UPSTREAM_SYNC.md pillar 2 says "touch a new upstream file -> add an
# entry in the same PR" -- a human-process instruction with no CI
# backstop. This script is that backstop: it computes the upstream
# files the fork actually modifies, in the map's own declared scope
# (src/** plus .gitignore -- see CONFLICT_HOTSPOTS.md's "Scope" note),
# and fails loudly if that set disagrees with what the map lists.
#
# Usage: scripts/check-conflict-hotspots.sh
# Exit 0 and silent on agreement; exit 1 with the mismatch on drift.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

hotspots_file="CONFLICT_HOTSPOTS.md"

# The fork's base: the parent of the first ptyxis-port commit. Computed
# rather than hardcoded so a future rebase (which rewrites every commit
# upstream of the fork's own history) does not silently stale this SHA --
# the marker is the *message* of the fork's first commit, not a hash.
first_fork_commit="$(git log --reverse --format='%H' --grep='^ptyxis-port:' | head -1)"
if [ -z "$first_fork_commit" ]; then
	echo "check-conflict-hotspots: no commit matching '^ptyxis-port:' found -- cannot locate the fork base" >&2
	exit 1
fi
base="$(git rev-parse "${first_fork_commit}^")"

# Files that exist at the base (i.e. upstream files, not ones the fork
# added outright) and that the fork has since modified.
modified_since_base="$(git diff --name-only "${base}..HEAD")"
files_at_base="$(git ls-tree -r --name-only "$base")"

actual_in_scope="$(
	printf '%s\n' "$modified_since_base" | while IFS= read -r f; do
		[ -z "$f" ] && continue
		case "$f" in
		src/* | .gitignore) ;;
		*) continue ;;
		esac
		printf '%s\n' "$files_at_base" | grep -qxF "$f" && printf '%s\n' "$f"
	done | sort -u
)"

# The map's own listed files: backtick-quoted paths in a "## `path` [+
# `path`...] — RISK risk" section header. Two files can share one header
# ("`src/config/Config.zig` + `src/config.zig` — HIGH risk"), so this
# extracts every backtick span from the header line, not just the first.
listed="$(
	awk '
		/^## / && / — (HIGH|MEDIUM|LOW) risk$/ {
			# Strip the trailing " — RISK risk" before extracting paths,
			# so a path is never accidentally read from the risk label.
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
stale_file="$(mktemp)"
actual_file="$(mktemp)"
listed_file="$(mktemp)"
trap 'rm -f "$missing_file" "$stale_file" "$actual_file" "$listed_file"' EXIT

printf '%s\n' "$actual_in_scope" >"$actual_file"
printf '%s\n' "$listed" >"$listed_file"

comm -23 "$actual_file" "$listed_file" >"$missing_file"
comm -13 "$actual_file" "$listed_file" >"$stale_file"
missing="$(cat "$missing_file")"
stale="$(cat "$stale_file")"

if [ -z "$missing" ] && [ -z "$stale" ]; then
	exit 0
fi

echo "check-conflict-hotspots: $hotspots_file has drifted from the fork's actual diff (base ${base})." >&2
echo >&2
if [ -n "$missing" ]; then
	echo "Modified upstream files with NO entry in $hotspots_file:" >&2
	printf '%s\n' "$missing" | sed 's/^/  /' >&2
	echo >&2
fi
if [ -n "$stale" ]; then
	echo "Entries in $hotspots_file for files that are no longer modified (the patch was upstreamed or dropped -- delete the entry per UPSTREAM_SYNC.md pillar 2):" >&2
	printf '%s\n' "$stale" | sed 's/^/  /' >&2
	echo >&2
fi
echo "See CONFLICT_HOTSPOTS.md's own instructions and UPSTREAM_SYNC.md pillar 2." >&2
exit 1
