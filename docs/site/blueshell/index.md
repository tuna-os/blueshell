---
sidebar_position: 1
sidebar_label: "BlueShell"

status: unknown
---

**A container-native terminal for GNOME — the Ghostty engine with the Ptyxis experience**

BlueShell is a fork of [Ghostty](https://ghostty.org) with
[Ptyxis](https://gitlab.gnome.org/chergert/ptyxis)'s features ported in. It
pairs Ghostty's GPU-accelerated terminal engine with the container-first
workflow Ptyxis pioneered for GNOME: Toolbox, Distrobox, and Podman
containers appear straight in the new-tab menu, profiles snapshot your
whole configuration, and a full Ptyxis-style preferences window drives
Ghostty's config live — no config-file editing required (though it's
still just `~/.config/ghostty/config` underneath, and always editable).

![GNOME 47+](https://img.shields.io/badge/GNOME-47%2B-blue)
![Zig](https://img.shields.io/badge/Zig-0.15-f7a41d)
![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-green)

## Features

**From the Ghostty engine:**

- **GPU-accelerated rendering** — HarfBuzz shaping, ligatures, fast scrollback
- **Kitty graphics protocol** — inline images in the terminal
- **OSC 8 hyperlinks**, splits, tab overview, fuzzy command palette
- **Standard Ghostty configuration** — every [Ghostty config option](https://ghostty.org/docs/config) works

**Ported from Ptyxis:**

- **Container tabs** — running Toolbox / Distrobox / Podman containers listed in the new-tab menu; one click opens a shell inside, via the ptyxis-agent PTY handoff
- **Profiles** — named snapshots of your full configuration with live switching and a per-profile editor (command, font, palette, opacity, cursor, scrollback, key compatibility)
- **Preferences window** — palette picker (244 palettes from the Gogh collection), font, cursor, scrolling, bells, notifications, shell integration, active-keybinding list with capture-to-rebind
- **Hamburger menu** — Ptyxis's theme swatches (system/light/dark) and zoom row
- **Libadwaita UI** — Wayland and X11, light and dark

## Installing

Released builds are published to the TunaOS Flatpak remote for x86_64 and
aarch64:

```bash
flatpak remote-add --if-not-exists tuna-os https://tunaos.org/flatpak/tuna-os.flatpakrepo
flatpak install tuna-os org.tunaos.BlueShell
```

The remote is an OCI index backed by `ghcr.io/tuna-os/blueshell`; see
[tuna-os/flatpak-index](https://github.com/tuna-os/flatpak-index). Builds are
pushed by `.github/workflows/publish-flatpak.yml` on every push to
`ptyxis-port`.

## Building

### Option A: Flatpak (recommended for testing)

```bash
flatpak-builder --install --user build-dir flatpak/org.tunaos.BlueShell.yml
```

### Option B: Native Zig build

Requires Zig 0.15.x and the GTK4/libadwaita stack (blueprint-compiler ≥ 0.16):

```bash
# Fedora 43+ (host or toolbox):
sudo dnf install blueprint-compiler gtk4-layer-shell-devel libadwaita-devel

zig build -Dapp-runtime=gtk -Doptimize=ReleaseFast
# Binary at zig-out/bin/ghostty
```

See [HACKING.md](https://github.com/tuna-os/blueshell/blob/ptyxis-port/HACKING.md)
for the full developer guide.

## Development

BlueShell is maintained as a patch-set on top of upstream Ghostty:

- **Upstream tracking** — a weekly CI rebase onto `ghostty-org/ghostty:main` opens a PR (clean) or a conflict issue with per-file resolution recipes; see [UPSTREAM_SYNC.md](https://github.com/tuna-os/blueshell/blob/ptyxis-port/UPSTREAM_SYNC.md)
- **Testing** — unit + integration suites that re-parse everything the preferences UI writes with Ghostty's real config parser, a headless UI smoke test, and an automated screenshot walkthrough uploaded as a CI artifact; see [TESTING.md](https://github.com/tuna-os/blueshell/blob/ptyxis-port/TESTING.md)
- **Fork-first layout** — Ptyxis features live in new files (`src/apprt/gtk/class/preferences_*.zig`, `profile_*.zig`, vendored `ptyxis-agent`) so upstream rebases stay small

## Credits

BlueShell exists because of two excellent projects, and is a fork of one
carrying the ideas of the other:

- **[Ghostty](https://ghostty.org)** by Mitchell Hashimoto — the terminal
  itself: emulation core, GPU renderer, GTK application runtime, splits,
  command palette. BlueShell is a downstream fork of Ghostty.
- **[Ptyxis](https://gitlab.gnome.org/chergert/ptyxis)** by Christian
  Hergert — the container-first UX this fork ports in: the container
  provider agent, profile system design, preferences layout, palette
  collection, and the container symbolic icons.

BlueShell is not affiliated with or endorsed by either project. Please
report BlueShell bugs to
[tuna-os/blueshell](https://github.com/tuna-os/blueshell/issues), never
upstream.

## License

GPL-3.0-or-later — matching both upstream projects.

## Related

- [Ghostty](https://ghostty.org) — the upstream terminal this forks
- [Ptyxis](https://gitlab.gnome.org/chergert/ptyxis) — the GNOME container terminal whose features are ported here
- [tuna-os/flatpak-index](https://github.com/tuna-os/flatpak-index) — the TunaOS Flatpak remote this ships through
