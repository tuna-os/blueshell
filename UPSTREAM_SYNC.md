# Staying in sync with upstream Ghostty

Blueshell is a patch-set on top of `ghostty-org/ghostty`. The whole
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

The run stands down in two cases: when `ptyxis-port` already contains
upstream's HEAD, and while an `upstream-sync/*` PR is still open —
otherwise the next run would stack a second branch and PR on an
overlapping commit range, and the two would conflict with each other
rather than with upstream. Merge or close the open one and the next run
resumes.

> The `upstream-sync` label has to exist on the repo. Labels do not
> survive a repository transfer, and every run between the 2026-08-17
> move into `tuna-os` and 2026-09-06 failed at `gh issue create --label
> upstream-sync` — on the conflict path only, so the workflow looked
> fine on any week that rebased cleanly.

### 2. The conflict map — `CONFLICT_HOTSPOTS.md`

Every upstream file we modify is listed there with *what* we changed,
*why it can break*, and a *resolution recipe*. When the sync run flags a
conflict, resolve using the recipe, and keep the file honest:

- Touch a new upstream file → add an entry in the same PR.
- Drop a patch (e.g. it was upstreamed) → delete the entry in the same
  commit.

`scripts/check-conflict-hotspots.sh` is the CI backstop for this: it
diffs `HEAD` against the fork's base commit and fails if any upstream
file modified by the fork diff is not listed in `CONFLICT_HOTSPOTS.md`.

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

## Publishing upstream Ghostty alongside Blueshell

`.github/workflows/publish-ghostty-flatpak.yml` builds **pinned
upstream Ghostty** (`com.mitchellh.ghostty`) and publishes it to the same
TunaOS Flatpak remote as Blueshell, so a user can install either terminal
— or both, since the app IDs differ — from one remote:

```sh
flatpak install tuna-os com.mitchellh.ghostty
```

The manifest is owned by this repo
(`flatpak/ghostty-stock/com.mitchellh.ghostty.yml`): it builds a pinned upstream
commit (a `type: git` source) with upstream's build commands unchanged,
plus one TunaOS addition — a launcher wrapper that passes the host's
`~/.config/ghostty` as optional config files, since Flatpak redirects
`XDG_CONFIG_HOME` into the sandbox (tuna-os/blueshell#117). No patches
to upstream's source. The workflow file is trigger policy only; the body
is the canonical reusable pipeline in `tuna-os/.github`.

The price of the wrapper is two vendored files
(`flatpak/ghostty-stock/dependencies.yml`,
`flatpak/ghostty-stock/zig-packages.json`), copied from upstream at the
pinned ref. Bumping the pin means refreshing them and diffing the
build-commands against the new ref's own manifest — the header comments
on each file say exactly how. Pull requests touching any of these files
get a build-only validation run (no publish), so pin bumps are checked
before they ship.

It runs weekly (Sundays 05:00 UTC) plus `workflow_dispatch`. Weekly, not
daily, because the reusable pipeline has no "upstream unchanged"
short-circuit — every run is two full Zig builds.

One upstream detail worth knowing: that manifest sets
`default-branch: tip`, while the remote's `tuna-os.flatpakrepo` declares
`DefaultBranch=master`. A `tip` ref would make the install fail with
"Nothing matches". Nothing patches it, and nothing needs to —
flatpak-builder resolves the branch as manifest `branch:` →
`--default-branch` → manifest `default-branch:`, and
`flatpak-github-actions` always passes `--default-branch=master`. Keep
that in mind before moving the build off that action.
