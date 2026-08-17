# GhosttyPtyxis — Container-native terminal powered by Ghostty

**GhosttyPtyxis** is a container-oriented terminal emulator for GNOME, combining the Ptyxis user experience with the Ghostty rendering engine. It brings first-class container support (Toolbox, Distrobox, Podman) together with Ghostty's high-performance HarfBuzz text rendering, Kitty graphics protocol, OSC 8 hyperlinks, GPU acceleration, and splits — packaged in Ptyxis's polished GNOME interface.

App ID: `dev.hanthor.GhosttyPtyxis`

---

## What makes it different

| | GhosttyPtyxis |
| --- | --- |
| **Renderer** | Ghostty — HarfBuzz, GPU-accelerated, Kitty graphics, OSC 8 hyperlinks, ligatures |
| **Container integration** | First-class — spawn shells in Toolbox / Distrobox / Podman from the new-tab menu via `ptyxis-agent` |
| **Profiles** | Ptyxis-style per-profile config snapshots — palette, font, opacity, cursor, command, scrollback |
| **Preferences window** | Full Ptyxis-style UI — palette picker, font, cursor, scrollback, window theme, shell integration, notifications |
| **Splits / tabs** | Ghostty splits + tab overview |
| **Command palette** | Ghostty fuzzy command palette |
| **Desktop** | GNOME / Libadwaita, Wayland + X11 |

---

## Installation

### Flatpak — one-line install (recommended)

CI builds a fresh Flatpak bundle on every commit to `ptyxis-port`. Install the latest:

```sh
curl -L https://nightly.link/hanthor/ghostty-ptyxis/workflows/ghostty-ptyxis/ptyxis-port/GhosttyPtyxis.flatpak.zip \
  -o GhosttyPtyxis.flatpak.zip \
  && unzip -o GhosttyPtyxis.flatpak.zip \
  && flatpak install --user --reinstall GhosttyPtyxis.flatpak
```

### Flatpak — build from source

```sh
flatpak-builder --install --user build-dir flatpak/dev.hanthor.GhosttyPtyxis.yml
```

### Build from source

Requires Zig 0.15.x and the GTK/Libadwaita development stack. On Fedora 43+:

```sh
# Inside a toolbox or on the host:
sudo dnf install blueprint-compiler gtk4-layer-shell-devel libadwaita-devel meson

# Download Zig 0.15.x from https://ziglang.org/download/ and put on PATH

git clone <this-repo> ghostty-ptyxis
cd ghostty-ptyxis
zig build -Dapp-runtime=gtk -Doptimize=ReleaseFast
# Binary at zig-out/bin/ghostty
```

See [HACKING.md](HACKING.md) for the full developer guide including the debug build workflow.
Also see [TESTING.md](TESTING.md) for the test architecture (unit, integration,
UI smoke, screenshot walkthrough), [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md) for how
the fork tracks upstream Ghostty, and
[docs/TUNA_OS_PROMOTION.md](docs/TUNA_OS_PROMOTION.md) for the tuna-os
promotion + Flatpak remote plan.

---

## Container integration

GhosttyPtyxis detects running Toolbox and Distrobox containers at startup and lists them in the new-tab menu. Selecting a container spawns a shell inside it via `ptyxis-agent`, which handles the D-Bus socket and PTY handoff.

Agent resolution order:

1. `PTYXIS_AGENT` environment variable
2. `/app/libexec/ptyxis-agent` (Flatpak bundle)
3. A sibling binary next to the `ghostty` executable

No extra configuration needed — if you have Toolbox or Distrobox installed, containers appear automatically.

---

## Profile system

Profiles are Ghostty config file snapshots stored in:

```
~/.config/ghostty/config                  ← active config Ghostty reads
~/.config/ghostty/profiles/<name>.config  ← named snapshots
~/.config/ghostty/profiles/.active        ← name of the currently active profile
```

**Switching** a profile copies the snapshot over the active config and triggers a live reload. **Saving** overwrites the snapshot from the current active config.

The per-profile editor (accessible from Preferences → Profiles → Edit…) lets you configure per-profile:

- Palette (full 244-palette picker)
- Font family, size, thicken
- Background opacity, cursor opacity
- Bold is bright
- Custom command, exit action, tab title prefix
- Backspace/Delete key compatibility
- Scrollback limit

---

## Preferences

Open with `Ctrl+,` or the hamburger menu.

**Appearance**
- Palette picker (244 palettes from the Gogh collection)
- Background transparency + blur
- Font family/size/thicken
- Line spacing, column spacing
- Cursor shape (block / hollow block / I-beam / underline), blinking, opacity

**Behavior**
- Tab bar visibility + position + wide tabs
- Window save state (restore on next launch)
- Mouse hide while typing, copy-on-select
- Scrollbar, scroll on keystroke/output, scrollback limit
- Shell integration
- Notify on command finish, desktop notifications
- Confirm before closing

**Shortcuts**
- Live list of active keybindings from the current config
- Quick access to open the config file or reload config

**Profiles**
- Create, switch, save, delete profiles
- Open the per-profile editor

---

## Key bindings (defaults)

| Action | Binding |
| --- | --- |
| New tab | `Ctrl+Shift+T` |
| Close tab | `Ctrl+Shift+W` |
| Next / previous tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Split right | `Ctrl+Shift+D` |
| Zoom in / out | `Ctrl+=` / `Ctrl+-` |
| Command palette | `Ctrl+Shift+P` |
| Preferences | `Ctrl+,` |
| Search | `Ctrl+Shift+F` |

All keybindings are configurable via `keybind = trigger=action` in `~/.config/ghostty/config`.

---

## Configuration

GhosttyPtyxis uses Ghostty's standard config format at `~/.config/ghostty/config`. All [Ghostty config options](https://ghostty.org/docs/config) are supported. Changes are applied live via Preferences or by editing the file and pressing `Ctrl+Shift+R`.

---

## Credits

- **[Ghostty](https://ghostty.org)** by Mitchell Hashimoto — terminal emulation engine, renderer, GTK apprt
- **[Ptyxis](https://gitlab.gnome.org/chergert/ptyxis)** by Christian Hergert — UI design, container integration, palette collection, profile system design
- **GhosttyPtyxis** ports Ptyxis's UI into Ghostty's GTK apprt as Zig

License: GPL-3.0-or-later (matching both upstream projects)
