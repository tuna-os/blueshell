# Blueshell Roadmap

**Last updated**: 2026-11-25 | **Status**: Shipping to the TunaOS Flatpak remote, latest release v1.3.1

Part of the [TunaOS](https://tunaos.org) ecosystem. A container-native GNOME
terminal: Ptyxis-style user experience on the Ghostty rendering engine,
maintained as a rebase-based patch set on `ghostty-org/ghostty`.

## What this file is

Feature scope lives in the [README](README.md); the fork strategy lives in
[UPSTREAM_SYNC.md](UPSTREAM_SYNC.md) and [CONFLICT_HOTSPOTS.md](CONFLICT_HOTSPOTS.md);
build and test practice lives in [HACKING.md](HACKING.md) and [TESTING.md](TESTING.md).

What none of those carry is the **maturity contract** — what has to be
demonstrably true before Blueshell is something the org tells people to depend
on, given that it is already installable from the org's remote. That is this
file.

For a fork, maturity is not primarily a feature question. Every feature in the
README already works. The open question is whether the *maintenance machinery*
works, because a fork whose upstream intake stalls becomes an unmaintained
snapshot of somebody else's fast-moving codebase without any single day on which
that decision was made.

## Current standing

| | |
|---|---|
| Distribution | `org.tunaos.blueshell` in the TunaOS Flatpak remote since 2026-08-27, `latest` tag, amd64 + arm64 |
| Versioning | `v1.3.1` released 2026-10-14, plus a rolling `tip` pre-release ([#59](https://github.com/tuna-os/blueshell/issues/59), closed) |
| Upstream freshness | Rebased onto upstream Ghostty `7597e85f` (committed upstream 2026-10-13) by [#142](https://github.com/tuna-os/blueshell/pull/142); no upstream commit has landed since ([#231](https://github.com/tuna-os/blueshell/issues/231)) |
| Upstream sync automation | `upstream-sync.yml` was repaired ([#57](https://github.com/tuna-os/blueshell/issues/57), closed) but has been switched off since 2026-10-15, so no weekly run has happened since ([#231](https://github.com/tuna-os/blueshell/issues/231)) |
| CI | `ptyxis-tests` and `zig-test` (`zig build test` on `ubuntu-latest`) run on every pull request; jobs inherited from upstream are guarded to run only in `ghostty-org/ghostty` ([#58](https://github.com/tuna-os/blueshell/issues/58), closed) |
| Governance | `.github/CODEOWNERS` routes risky paths (`.github/`, container, sudoers, polkit, SSH and signing files) to `@hanthor`; GitHub reads it before the root `CODEOWNERS` inherited from upstream |
| Second upstream | `third_party/ptyxis-agent` carries origin, revision and license in `PROVENANCE.md` ([#56](https://github.com/tuna-os/blueshell/issues/56), closed) |

## Gate 1 — the fork sustains itself

Nothing below this gate is a feature. It is the set of properties that decide
whether Blueshell is a maintained fork or a snapshot, and it is the highest
priority work in the repository.

| Gate | Required evidence |
|---|---|
| The alarm can fire | One `upstream-sync.yml` run that reaches the conflict path and successfully opens the issue — which needs `issues: write` in the workflow's `permissions` and an `upstream-sync` label that exists. Both are now in place; the conflict path has still not run on a schedule, because the workflow is switched off ([#231](https://github.com/tuna-os/blueshell/issues/231)) |
| The rebase lands | One upstream sync merged to `ptyxis-port`, closing the gap that has stood since 2026-06-03, with `upstream-sync/2026-06-08` and `upstream-sync/2026-06-15` deleted rather than left implying pending work. In part: [#142](https://github.com/tuna-os/blueshell/pull/142) merged the rebase onto `7597e85f` on 2026-10-14, but both stale branches still exist |
| Drift is detected, not just conflicted | Upstream's `test.yml` green on a runner this org actually has — at minimum the Linux/GTK subset, since this fork ships neither macOS nor Windows. `UPSTREAM_SYNC.md`'s fourth pillar assumes this suite runs |
| The conflict map is true | Met: [#55](https://github.com/tuna-os/blueshell/issues/55) closed — `scripts/check-conflict-hotspots.sh` runs in `ptyxis-tests` and checks `CONFLICT_HOTSPOTS.md` against the files actually patched |
| The second upstream has a contract | Met: [#56](https://github.com/tuna-os/blueshell/issues/56) closed — `third_party/ptyxis-agent/PROVENANCE.md` states origin, revision and license |

**Sustained-sync definition of done**: three consecutive weekly syncs that either
merge cleanly or open a conflict issue that a human closes within the week. One
green run proves the workflow; three prove the chore.

## Gate 2 — the release contract

Reachable once Gate 1 holds, because for a fork the two are the same mechanism:
a release is *an upstream sync plus the fork's own changes*, and cutting one
without the other publishes drift.

| Gate | Required evidence |
|---|---|
| A version exists | A version tagged from `ptyxis-port`, carried into the Flatpak publish alongside `latest`, so the remote offers something pinnable and a bug report can name a build. In part: `v1.3.1` is tagged and its release carries the Flatpak bundles, but `publish-flatpak.yml` still pushes the remote image as `latest` only |
| Provenance is stated | Release notes naming the upstream Ghostty commit the build is rebased on. For a fork this is the load-bearing field — it is the answer to "which upstream fixes do I have" |
| The front page matches reality | Met: README Installation leads with the TunaOS remote (`flatpak remote-add … tuna-os.flatpakrepo`) |
| Publish is gated | The Flatpak publish refuses to run past a stated upstream-staleness threshold. Shipping to a user-facing remote from an unbounded gap is what turns a maintenance problem into a user-facing one |
| Rollback is an operation | A prior tagged digest retained in the index and a documented procedure for pointing the remote back at it |

## Gate 3 — a project someone else can join

| Gate | Required evidence |
|---|---|
| Review routing resolves | CODEOWNERS mapped to real owners, or reduced to the fork-owned paths (`preferences_window.zig`, `preferences_logic.zig`, `profile_store.zig`, `config_bridge.zig`, `test/ui/`, workflows) |
| The branch is protected | Required checks on `ptyxis-port` — its ruleset blocks deletion and force-push but requires no status check, so the path to the public remote has no gate |
| Governance is decided | The five `vouch-*` workflows are either made to run or removed. A half-wired governance mechanism is worse than an explicit BDFL line, and a working one would be a candidate answer to the org's open governance gap (`tunaos#1168`) |
| Entry points exist | Repository topics, a homepage link, and `good first issue` applied to work that qualifies — the labels exist and are unused |
| Workflow inventory is honest | Every workflow either runs or is deleted; 15 that structurally cannot run make CI health unreadable for everyone after |

## Upstreaming

The cheapest long-term maintenance strategy is a smaller patch set, and
`UPSTREAM_SYNC.md`'s third pillar says so: *"every accepted patch is a hotspot
entry deleted forever."* [#6](https://github.com/tuna-os/blueshell/issues/6)
(external `master_fd` adoption in `termio.Exec`) was the first candidate; it was
closed as not planned. Each hotspot entry should carry a standing question —
can this go upstream? — and the answer belongs in `CONFLICT_HOTSPOTS.md` next
to the recipe.

Sibling direction: [#23](https://github.com/tuna-os/blueshell/issues/23) (closed)
asked `tuna-os/corral` for machine-readable `corral list --json`, which is the
container-integration seam Blueshell owns end to end within the org.

## Deliberately not now

- **macOS and Windows** — upstream supports both; this fork ships a GNOME/
  Libadwaita application and inherits those workflows without using them
- **Snap and Nix packaging** — manifests are inherited and unexercised; the
  Flatpak remote is the one supported channel until it has a version contract
- **A second desktop target** — the Ptyxis experience is GNOME-specific by design

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [HACKING.md](HACKING.md) and
[TESTING.md](TESTING.md). The fork's own test suite (`ptyxis-tests`) and
`zig-test` run on every pull request. No check is required on `ptyxis-port` yet
(Gate 3), so treat both as the contract.
