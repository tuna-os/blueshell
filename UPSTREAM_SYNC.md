# Staying in sync with upstream Ghostty

BlueShell is a patch-set on top of `ghostty-org/ghostty`. The whole
strategy is built around one goal: **keep the downstream diff small,
mechanical to re-apply, and loudly alarmed** so weekly rebases stay a
15-minute chore instead of a rescue mission.

## The four pillars

### 1. Automated weekly rebase — `.github/workflows/upstream-sync.yml`

Every Monday 09:00 UTC (and on manual dispatch) CI fetches
`ghostty-org/ghostty:main` and attempts `git rebase` of `ptyxis-port`:

- **Clean rebase** → pushes `upstream-sync/<date>` and opens a PR
  against `ptyxis-port`. Merge it after CI (`ptyxis-tests` +
  `ghostty-ptyxis` flatpak) is green.
- **Conflicts** → opens an issue labeled `upstream-sync` listing the
  conflicted files and the upstream commit range, with local
  reproduction steps.

### 2. The conflict map — `CONFLICT_HOTSPOTS.md`

Every upstream file we modify is listed there with *what* we changed,
*why it can break*, and a *resolution recipe*. When the sync run flags a
conflict, resolve using the recipe, and keep the file honest:

- Touch a new upstream file → add an entry in the same PR.
- Drop a patch (e.g. it was upstreamed) → delete the entry in the same
  commit.

### 3. Additions over modifications

Fork code lives in **new files** wherever possible
(`preferences_window.zig`, `preferences_logic.zig`, `profile_store.zig`,
`config_bridge.zig`, `test/ui/`, workflows). New files can't conflict.
The residual patches to upstream files are deliberately tiny and
documented in the hotspots map. When a patch could serve upstream, send
it upstream (see issue #6 pattern) — every accepted patch is a hotspot
entry deleted forever.

### 4. Drift alarms — the test suite

Rebases that *merge cleanly but break behavior* are the dangerous ones.
The fork's tests (see `TESTING.md`) are written to convert silent drift
into red CI on the sync PR:

- Every preference-UI combo table is checked **bidirectionally** against
  the corresponding upstream config enum: an upstream member added,
  renamed, or removed fails `preferences_logic` tests even though no
  file conflicted.
- Everything the UI writes is re-parsed by upstream's real config
  parser with zero-diagnostic assertions, so upstream key renames or
  syntax changes surface immediately.
- The headless smoke test catches blueprint/libadwaita/template
  breakage from upstream UI-toolkit bumps.

## Operator playbook

Weekly, when the sync PR/issue arrives:

1. **PR, CI green** → merge. Done.
2. **PR, CI red** → the diff merged but semantics drifted; the failing
   test names point at the table/key to update (usually a one-line
   table + blueprint string-list addition).
3. **Issue (conflicts)** → follow the reproduction block in the issue,
   resolve each file with its `CONFLICT_HOTSPOTS.md` recipe, push the
   branch, open the PR, let CI vouch for it.

Tracking upstream **releases** instead of `main` is a deliberate
non-goal while the fork iterates quickly; if that changes, point the
workflow's `fetch upstream main` at the release tag instead.
