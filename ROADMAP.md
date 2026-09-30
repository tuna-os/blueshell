# BlueShell Roadmap

**Last updated**: 2026-09-02 | **Status**: Shipping to the TunaOS Flatpak remote, unversioned

Part of the [TunaOS](https://tunaos.org) ecosystem. A container-native GNOME
terminal: Ptyxis-style user experience on the Ghostty rendering engine,
maintained as a rebase-based patch set on `ghostty-org/ghostty`.

## What this file is

Feature scope lives in the [README](README.md); the fork strategy lives in
[UPSTREAM_SYNC.md](UPSTREAM_SYNC.md) and [CONFLICT_HOTSPOTS.md](CONFLICT_HOTSPOTS.md);
build and test practice lives in [HACKING.md](HACKING.md) and [TESTING.md](TESTING.md).

What none of those carry is the **maturity contract** — what has to be
demonstrably true before BlueShell is something the org tells people to depend
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
| Distribution | `org.tunaos.BlueShell` in the TunaOS Flatpak remote since 2026-08-27, `latest` tag, amd64 + arm64 |
| Versioning | None — 0 tags, 0 releases, 0 milestones ([#59](https://github.com/tuna-os/blueshell/issues/59)) |
| Upstream freshness | No upstream Ghostty commit newer than 2026-06-03 ([#57](https://github.com/tuna-os/blueshell/issues/57)) |
| Upstream sync automation | 13 scheduled runs, 13 failures, no successful run ([#57](https://github.com/tuna-os/blueshell/issues/57)) |
| CI | 4 of 19 workflows execute; upstream's `Test` suite has never completed here ([#58](https://github.com/tuna-os/blueshell/issues/58)) |
| Governance | CODEOWNERS assigns every path to `@ghostty-org/*` teams that do not exist in this org ([#58](https://github.com/tuna-os/blueshell/issues/58)) |
| Second upstream | `third_party/ptyxis-agent` vendored without provenance ([#56](https://github.com/tuna-os/blueshell/issues/56)) |

## Gate 1 — the fork sustains itself

Nothing below this gate is a feature. It is the set of properties that decide
whether BlueShell is a maintained fork or a snapshot, and it is the highest
priority work in the repository.

| Gate | Required evidence |
|---|---|
| The alarm can fire | One `upstream-sync.yml` run that reaches the conflict path and successfully opens the issue — which needs `issues: write` in the workflow's `permissions` and an `upstream-sync` label that exists. Both are missing today, and `docs/TUNA_OS_PROMOTION.md` §1 already warned that the label had to survive the org transfer |
| The rebase lands | One upstream sync merged to `ptyxis-port`, closing the gap that has stood since 2026-06-03, with `upstream-sync/2026-06-08` and `upstream-sync/2026-06-15` deleted rather than left implying pending work |
| Drift is detected, not just conflicted | Upstream's `test.yml` green on a runner this org actually has — at minimum the Linux/GTK subset, since this fork ships neither macOS nor Windows. `UPSTREAM_SYNC.md`'s fourth pillar assumes this suite runs |
| The conflict map is true | [#55](https://github.com/tuna-os/blueshell/issues/55) resolved — `CONFLICT_HOTSPOTS.md` matches the files actually patched, checked by something other than memory |
| The second upstream has a contract | [#56](https://github.com/tuna-os/blueshell/issues/56) resolved — `third_party/ptyxis-agent` carries a stated origin, revision and license |

**Sustained-sync definition of done**: three consecutive weekly syncs that either
merge cleanly or open a conflict issue that a human closes within the week. One
green run proves the workflow; three prove the chore.

## Gate 2 — the release contract

Reachable once Gate 1 holds, because for a fork the two are the same mechanism:
a release is *an upstream sync plus the fork's own changes*, and cutting one
without the other publishes drift.

| Gate | Required evidence |
|---|---|
| A version exists | `v0.1.0` tagged from `ptyxis-port`, carried into the Flatpak publish alongside `latest`, so the remote offers something pinnable and a bug report can name a build |
| Provenance is stated | Release notes naming the upstream Ghostty commit the build is rebased on. For a fork this is the load-bearing field — it is the answer to "which upstream fixes do I have" |
| The front page matches reality | README leads with the TunaOS remote install rather than the `nightly.link` bundle, which has been the supported path since 2026-08-27 |
| Publish is gated | The Flatpak publish refuses to run past a stated upstream-staleness threshold. Shipping to a user-facing remote from an unbounded gap is what turns a maintenance problem into a user-facing one |
| Rollback is an operation | A prior tagged digest retained in the index and a documented procedure for pointing the remote back at it |

## Gate 3 — a project someone else can join

| Gate | Required evidence |
|---|---|
| Review routing resolves | CODEOWNERS mapped to real owners, or reduced to the fork-owned paths (`preferences_window.zig`, `preferences_logic.zig`, `profile_store.zig`, `config_bridge.zig`, `test/ui/`, workflows) |
| The branch is protected | Required checks on `ptyxis-port` — currently none of the 15 branches is protected, so the path to the public remote has no gate |
| Governance is decided | The five `vouch-*` workflows are either made to run or removed. A half-wired governance mechanism is worse than an explicit BDFL line, and a working one would be a candidate answer to the org's open governance gap (`tunaos#1168`) |
| Entry points exist | Repository topics, a homepage link, and `good first issue` applied to work that qualifies — the labels exist and are unused |
| Workflow inventory is honest | Every workflow either runs or is deleted; 15 that structurally cannot run make CI health unreadable for everyone after |

## Upstreaming

The cheapest long-term maintenance strategy is a smaller patch set, and
`UPSTREAM_SYNC.md`'s third pillar says so: *"every accepted patch is a hotspot
entry deleted forever."* [#6](https://github.com/tuna-os/blueshell/issues/6)
(external `master_fd` adoption in `termio.Exec`) is the pattern. Each hotspot
entry should carry a standing question — can this go upstream? — and the answer
belongs in `CONFLICT_HOTSPOTS.md` next to the recipe.

Sibling direction: [#23](https://github.com/tuna-os/blueshell/issues/23) asks
`tuna-os/corral` for machine-readable `corral list --json`, which is the
container-integration seam BlueShell owns end to end within the org.

## Deliberately not now

- **macOS and Windows** — upstream supports both; this fork ships a GNOME/
  Libadwaita application and inherits those workflows without using them
- **Snap and Nix packaging** — manifests are inherited and unexercised; the
  Flatpak remote is the one supported channel until it has a version contract
- **A second desktop target** — the Ptyxis experience is GNOME-specific by design

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [HACKING.md](HACKING.md) and
[TESTING.md](TESTING.md). The fork's own test suite (`ptyxis-tests`) is the one
CI job that currently gates merges; treat it as the contract until Gate 1's
`test.yml` work lands.
