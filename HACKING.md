# Developing Blueshell

This document covers building and hacking on **Blueshell** (the `ptyxis-port` branch). The second half of this file is the upstream Ghostty developer guide, which applies equally here for anything not covered in the Blueshell section.

<!-- hive-contribute-plea: donated-compute appeal, keep in sync across repos -->
## Contribute compute — no code needed

**[Donate time with your AI CLI](https://hub.tunaos.org/#contribute).**

Your machine runs one task at a time using your signed-in AI coding CLI.
The relay alternates between eligible **School** (OS) and **Reef** (apps)
hives after each task. If one hive has no work, the other can continue.

The guide covers prerequisites, verified `just` setup, credentials, provider
costs, and how to stop with Ctrl+C. Your subscription quota or API charges apply.
Never post account credentials or API keys in issues or pull requests.

## Quick start (Fedora / Silverblue)

Blueshell builds inside a Fedora 43 toolbox. The host needs Zig 0.15.x on PATH.

```sh
# One-time: create the build toolbox
toolbox create --image registry.fedoraproject.org/fedora-toolbox:43 finupdate
toolbox enter finupdate
sudo dnf install blueprint-compiler gtk4-layer-shell-devel libadwaita-devel \
    meson gtk4-devel gobject-introspection-devel

# Zig 0.15.x (run on the host — $HOME is shared)
curl -L https://ziglang.org/download/0.15.0/zig-x86_64-linux-0.15.0.tar.xz | tar xJ -C ~/.local/
ln -sf ~/.local/zig-x86_64-linux-0.15.0/zig ~/.local/bin/zig
```

Build the GTK app:

```sh
toolbox run --container finupdate bash -c "zig build -Dapp-runtime=gtk"
# Debug binary → zig-out/bin/ghostty
```

Run it:

```sh
toolbox run --container finupdate zig-out/bin/ghostty
```

For release builds add `-Doptimize=ReleaseFast`.

## Source layout (ptyxis-specific files)

All Ptyxis UI code lives under `src/apprt/gtk/`:

| Path | Purpose |
| --- | --- |
| `class/preferences_window.zig` | Full preferences window — palette, font, cursor, behavior, shortcuts, profiles |
| `class/profile_editor.zig` | Per-profile editor dialog |
| `class/profile_store.zig` | Profile CRUD — snapshot files in `~/.config/ghostty/profiles/` |
| `class/config_bridge.zig` | Read/write individual keys in a Ghostty config file |
| `class/palette.zig` | Palette data model; `palettes_embed.zig` embeds the Gogh JSON at build time |
| `class/container_client.zig` | D-Bus ContainerClient — ListContainers / CreatePty / Spawn |
| `class/container_object.zig` | GObject wrapper for a discovered container |
| `class/window.zig` | Hamburger menu, theme picker, zoom, container new-tab picker |
| `ui/1.5/preferences-window.blp` | Blueprint for the preferences window |
| `ui/1.5/profile-editor.blp` | Blueprint for the profile editor |
| `third_party/ptyxis-agent/` | Bundled ptyxis-agent (standalone meson build) |

## Building ptyxis-agent

`ptyxis-agent` is vendored as a standalone meson subproject:

```sh
cd third_party/ptyxis-agent
meson setup build
meson compile -C build
# Binary → third_party/ptyxis-agent/build/ptyxis-agent
```

The GTK app auto-resolves it from `PTYXIS_AGENT`, `/app/libexec/ptyxis-agent`, or a sibling path.

## Flatpak build

```sh
flatpak-builder --install --user build-dir flatpak/org.tunaos.blueshell.yml
```

The manifest bundles ptyxis-agent at `/app/libexec/ptyxis-agent`.

## BlueShell GTK Application Architecture

BlueShell replaces upstream Ghostty's standard GTK interface with a modern Libadwaita application inspired by Ptyxis. This section details how the GTK port is structured, how components interact, and how to extend or debug the UI.

### Architectural Fit & Relationship to Ghostty

Upstream Ghostty defines an abstract application runtime layer (`src/apprt.zig`) that decouples terminal core logic (VT parsing, render scheduling, surface management) from platform windowing toolkits (macOS Cocoa, GTK, web).

When compiling with `-Dapp-runtime=gtk`:
- `src/apprt.zig` selects `src/apprt/gtk.zig`, routing into `src/apprt/gtk/App.zig` and `src/apprt/gtk/Surface.zig`.
- `App.zig` creates and initializes `src/apprt/gtk/class/application.zig` (`GhosttyPtyxisApplication`), a subclass of `Adw.Application` (and `Gtk.Application`).
- Upstream Ghostty's traditional GTK stubs and window widgets are replaced by BlueShell's Ptyxis-style widgets:
  - `class/window.zig` (`GhosttyPtyxisWindow`): The main terminal window featuring tab overview, modern header bar with container dropdown, zoom controls, and hamburger menu.
  - `class/preferences_window.zig` (`GhosttyPtyxisPreferencesWindow`): Libadwaita preferences window organized into pages (Appearance, Behavior, Shortcuts, Profiles).
  - `class/profile_editor.zig` (`GhosttyPtyxisProfileEditor`): Modal dialog for editing per-profile shell commands, palettes, and configurations.
  - `class/tab.zig` and `class/split_tree.zig`: Manage terminal tab organization and split panes wrapping terminal surfaces (`Surface.zig`).

### Component Overview

```
                          ┌────────────────────────┐
                          │ Ghostty Core / Config  │
                          └───────────▲────────────┘
                                      │
                         triggerReload() / getConfig()
                                      │
 ┌────────────────────────────────────┴────────────────────────────────────┐
 │ BlueShell GTK Application (`src/apprt/gtk/`)                            │
 │                                                                         │
 │  ┌────────────────────────┐                   ┌──────────────────────┐  │
 │  │   PreferencesWindow    │                   │        Window        │  │
 │  │   (Libadwaita / UI)    │                   │   (Header / Tabs)    │  │
 │  └───────────┬────────────┘                   └──────────▲───────────┘  │
 │              │ writes keys                               │ displays     │
 │              ▼                                           │              │
 │  ┌────────────────────────┐                   ┌──────────┴───────────┐  │
 │  │     config_bridge      │                   │   container_object   │  │
 │  │ (plain-text ~/.config) │                   │  (GObject container) │  │
 │  └───────────┬────────────┘                   └──────────▲───────────┘  │
 │              │ manages profiles                          │ wraps        │
 │              ▼                                           │              │
 │  ┌────────────────────────┐                   ┌──────────┴───────────┐  │
 │  │     profile_store      │                   │   container_client   │  │
 │  │ (~/profiles/*.config)  │                   │ (GDBus / socketpair) │  │
 │  └────────────────────────┘                   └──────────▲───────────┘  │
 └──────────────────────────────────────────────────────────┼──────────────┘
                                                            │ peer-to-peer
                                                            │ GDBus
                                                 ┌──────────▼───────────┐
                                                 │     ptyxis-agent     │
                                                 │ (Podman/Toolbox/etc) │
                                                 └──────────────────────┘
```

The primary subsystems are:
1. **Preferences Window (`class/preferences_window.zig`)**: Implements Libadwaita preference pages with live-updating controls for fonts, Gogh palettes, cursor appearance, bell alerts, scrollback limits, and shortcuts.
2. **Profile Store (`class/profile_store.zig`)**: Manages isolated profile configuration snapshots stored on disk.
3. **Config Bridge (`class/config_bridge.zig`)**: Safe, non-destructive plain-text parser and writer for Ghostty configuration files.
4. **Container Client (`class/container_client.zig`)**: Asynchronous D-Bus client interacting with `ptyxis-agent`.
5. **Container Object (`class/container_object.zig`)**: GObject wrapper exposing container metadata to GTK selection models.
6. **ptyxis-agent (`third_party/ptyxis-agent/`)**: Daemon discovering and spawning containerized environments (Toolbox, Distrobox, Podman).

### Data Flow: Config Changes, Bridge, and Reload

Ghostty config is read from plain-text files (typically `~/.config/ghostty/config`) without an upstream roundtripping serializer. BlueShell coordinates preference edits through `config_bridge`:

1. **User Interaction**: User toggles a switch, picks a font, or adjusts a slider in the preferences window.
2. **Signal Dispatch**: GTK signal callback (e.g., `notify::active`, `value-changed`) fires.
3. **Write via Config Bridge**:
   - `config_bridge.setKey(allocator, key, value, maybe_path)` is invoked.
   - If `maybe_path` is `null`, it targets the active Ghostty config path (resolved via `config_bridge.resolveConfigPath`).
   - If `maybe_path` is specified, it writes directly to a target profile snapshot.
   - `config_bridge` preserves existing comments, replaces the last assignment of `key = value` if present (respecting Ghostty's "later wins" precedence), or appends a new assignment line.
4. **Debounced Reload**:
   - The UI calls `Application.default().triggerReload()`.
   - `triggerReload()` queues a 300ms debounced timer via `glib.timeoutAdd`. Rapid successive changes (e.g., dragging an opacity slider) collapse into a single reload cycle.
   - Upon timer expiry, `Application` reloads the active configuration and applies changes across all active windows and surfaces.

### Profile Lifecycle

BlueShell implements a snapshot-based profile management pattern:
- **Storage Layout**:
  - `~/.config/ghostty/config`: Active Ghostty configuration file currently loaded by the runtime.
  - `~/.config/ghostty/profiles/{name}.config`: Named profile snapshots.
  - `~/.config/ghostty/profiles/.active`: Plain text file recording the currently active profile name.
- **Lifecycle Phases**:
  1. **Load**: On startup or preferences launch, `profile_store.listProfiles()` scans `~/.config/ghostty/profiles/`, reading `.active` to flag which profile is active.
  2. **Edit**: Editing a profile in `profile_editor.zig` writes directly to `~/.config/ghostty/profiles/{name}.config` via `config_bridge.setKey(..., priv.profile_path)`.
  3. **Save & Sync**: If the edited profile is currently active, `self.syncActiveProfile()` copies changes over to `~/.config/ghostty/config` and calls `triggerReload()`.
  4. **Apply (Switch)**: `profile_store.activateProfile(name)` copies the requested `{name}.config` snapshot over the active `~/.config/ghostty/config`, updates `.active`, and prompts `Application.default().triggerReload()`.

### Container Discovery & D-Bus Client

BlueShell integrates containerized shell environments without requiring root privileges or external system daemons:

1. **Process Spawning**:
   - When initialized, `container_client.zig` creates a UNIX stream socket pair using `socketpair(AF_UNIX, SOCK_STREAM | CLOEXEC, 0)`.
   - The parent side wraps file descriptor 0 into a `GSocket` and `GSocketConnection`.
   - The child side file descriptor is passed to `ptyxis-agent` via file descriptor 3 (`--socket-fd=3`) using `gio.SubprocessLauncher.takeFd`.
2. **Peer-to-Peer D-Bus Connection**:
   - BlueShell opens a private, peer-to-peer `GDBusConnection` over the stream (`authentication_server = true`, `authentication_allow_anonymous = true`).
   - `ptyxis-agent` exposes the `org.gnome.Ptyxis.Agent` interface at `/org/gnome/Ptyxis/Agent`.
3. **Query & GObject Wrapping**:
   - `client.listContainers()` invokes the `ListContainers` method on `/org/gnome/Ptyxis/Agent`, retrieving object paths for all discovered container instances (e.g., Toolbox, Podman, Distrobox).
   - For each container path, properties (`id`, `provider`, `display-name`, `icon-name`) are queried from `org.gnome.Ptyxis.Container`.
   - `client.listAsModel()` wraps each entry in a `GhosttyPtyxisContainer` (`container_object.zig`) GObject and inserts it into a `Gio.ListStore`.
4. **UI Presentation**:
   - Main window header dropdowns consume the `Gio.ListStore` to display available containers with matching icons and names for one-click tab spawning.

### ptyxis-agent Integration

`ptyxis-agent` is vendored directly under `third_party/ptyxis-agent/`:
- **Purpose**: A small, privileged-operation helper originally developed for GNOME Ptyxis. It interfaces with local container managers (Toolbox, Podman, Distrobox, JHBuild) to discover running environments and safely spawn pseudo-terminals inside them.
- **Why Vendored**: Bundled as a standalone C Meson subproject to avoid requiring upstream GNOME Ptyxis or distro-level packaging dependencies, ensuring reproducible Flatpak and native builds.
- **Updating ptyxis-agent**:
  1. Update sources in `third_party/ptyxis-agent/` from upstream Ptyxis.
  2. Inspect changes in `third_party/ptyxis-agent/meson.build` and IPC interface definitions in `org.gnome.Ptyxis.Agent.xml`.
  3. Rebuild locally: `cd third_party/ptyxis-agent && meson setup build && meson compile -C build`.
  4. Verify compatibility with `src/apprt/gtk/class/container_client.zig`.

### Blueprint Compilation & GTK Signal Wiring

BlueShell designs its UI declaratively using Blueprint (`.blp`), which compiles to standard GtkBuilder XML at build time:
- **Blueprint Definitions**: Located in `src/apprt/gtk/ui/1.5/*.blp`.
- **GResource Embedding**: Compiled blueprints are embedded into GResource bundles (`src/apprt/gtk/build/gresource.zig`).
- **Template Binding**:
  - Classes bind their template with `class.setTemplate(gresource.blueprint(.{ .major = 1, .minor = 5, .name = "..." }))`.
  - Child widgets declared in Blueprint are mapped to Zig struct fields in `Class.init` using `class.bindTemplateChildPrivate("widget_name", .{})`.
- **Signal Connections**:
  - Signal handlers are connected in `init` using `gobject.signalConnectData` (e.g., connecting `notify::active` or `clicked` to callback functions).

### Code Examples: Adding Preferences

The following pattern illustrates how preferences are wired between Blueprint, the private class struct, and `config_bridge`.

#### Example 1: Font Selection (`FontDialogButton`)

In `ui/1.5/preferences-window.blp`:
```blueprint
Adw.ActionRow custom_font_row {
  title: _("Custom Font");
  activatable-widget: font_button;

  [suffix]
  FontDialogButton font_button {
    valign: center;
    dialog: FontDialog {
      title: _("Choose a Terminal Font");
      modal: true;
    };
  }
}
```

In `src/apprt/gtk/class/preferences_window.zig`:
```zig
// 1. Declare struct member
const Private = struct {
    font_button: *gtk.FontDialogButton,
    // ...
};

// 2. Bind template child in Class.init
fn classInit(class: *Class) void {
    class.bindTemplateChildPrivate("font_button", .{});
}

// 3. Connect signal in instance init
fn init(self: *Self) void {
    const priv = self.private();
    _ = gobject.signalConnectData(
        priv.font_button.as(gobject.Object),
        "notify::font-desc",
        @ptrCast(&fontDescChanged),
        self,
        null,
        .{},
    );
}

// 4. Handle change and write via config_bridge
fn fontDescChanged(btn: *gtk.FontDialogButton, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
    const desc = btn.getFontDesc() orelse return;
    const str_z = pango_font_description_to_string(@ptrCast(desc));
    defer g_free(@ptrCast(@constCast(str_z)));

    const parts = logic.splitFontDesc(std.mem.span(str_z));
    config_bridge.setKey(std.heap.c_allocator, "font-family", parts.family, null) catch |err| {
        log.warn("font-family write: {s}", .{@errorName(err)});
    };
    if (parts.size) |size| {
        config_bridge.setKey(std.heap.c_allocator, "font-size", size, null) catch |err| {
            log.warn("font-size write: {s}", .{@errorName(err)});
        };
    }
    Application.default().triggerReload();
}
```

#### Example 2: Palette Selector (`FlowBox` with Dynamic CSS)

In `preferences_window.zig`, palette cards are created dynamically and added to `palette_flowbox`:
```zig
// When a user selects a palette swatch card:
fn onPaletteClicked(btn: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
    const ptr = gobject.Object.getData(btn.as(gobject.Object), "ptyxis-palette-id") orelse return;
    const id_cstr: [*:0]const u8 = @ptrCast(ptr);
    const id = std.mem.span(id_cstr);

    applyPalette(id) catch |err| {
        log.warn("applyPalette({s}) failed: {s}", .{ id, @errorName(err) });
    };
}

pub fn applyPaletteToPath(id: []const u8, maybe_path: ?[]const u8) !void {
    // Writes light and dark variants to Ghostty theme files and updates config
    try config_bridge.setKey(alloc, "theme", theme_spec, maybe_path);
    Application.default().triggerReload();
}
```

### Testing UI Changes

Before submitting GTK changes, test them using the provided headless automation test scripts under `test/ui/`:

1. **Headless Smoke Test (`test/ui/smoke.sh`)**:
   - Launches Ghostty under `xvfb-run` and `dbus-run-session` using an isolated configuration directory.
   - Instantiates GTK blueprint templates, verifying template child bindings, GResource paths, and basic lifecycle stability without requiring a physical monitor.
   ```sh
   test/ui/smoke.sh [path-to-ghostty-binary]
   ```

2. **Screenshot Walkthrough Test (`test/ui/walkthrough.sh`)**:
   - Drives Ghostty under Xvfb through all preferences pages and main window states.
   - Captures PNG screenshots in `test/ui/screenshots/` (using ImageMagick `import`) for automated regression checking and visual inspection.
   ```sh
   test/ui/walkthrough.sh [path-to-ghostty-binary] [output-dir]
   ```

---

# Developing Ghostty

This document describes the technical details behind Ghostty's development.
If you'd like to open any pull requests or would like to implement new features
into Ghostty, please make sure to read our ["Contributing to Ghostty"](CONTRIBUTING.md)
document first.

To start development on Ghostty, you need to build Ghostty from a Git checkout,
which is very similar in process to [building Ghostty from a source tarball](http://ghostty.org/docs/install/build). One key difference is that obviously
you need to clone the Git repository instead of unpacking the source tarball:

```shell
git clone https://github.com/ghostty-org/ghostty
cd ghostty
```

> [!NOTE]
>
> Ghostty may require [extra dependencies](#extra-dependencies)
> when building from a Git checkout compared to a source tarball.
> Tip versions may also require a different version of Zig or other toolchains
> (e.g. the Xcode SDK on macOS) compared to stable versions — make sure to
> follow the steps closely!

When you're developing Ghostty, it's very likely that you will want to build a
_debug_ build to diagnose issues more easily. This is already the default for
Zig builds, so simply run `zig build` **without any `-Doptimize` flags**.

There are many more build steps than just `zig build`, some of which are listed
here:

| Command                         | Description                                                                                                            |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `zig build run`                 | Runs Ghostty                                                                                                           |
| `zig build run-valgrind`        | Runs Ghostty under Valgrind to [check for memory leaks](#checking-for-memory-leaks)                                    |
| `zig build test`                | Runs unit tests (accepts `-Dtest-filter=<filter>` to only run tests whose name matches the filter)                     |
| `zig build update-translations` | Updates Ghostty's translation strings (see the [Contributor's Guide on Localizing Ghostty](po/README_CONTRIBUTORS.md)) |
| `zig build dist`                | Builds a source tarball                                                                                                |
| `zig build distcheck`           | Builds and validates a source tarball                                                                                  |

## Extra Dependencies

### Linux

Building Ghostty from a Git checkout on Linux requires some additional
dependencies:

- `blueprint-compiler` (version 0.16.0 or newer)

### macOS

Building the Ghostty macOS app requires that Xcode, the macOS SDK,
and Metal Toolchain are all installed.

A common issue is that the incorrect version of Xcode is either
installed or selected. Use the `xcode-select` command to
ensure that the correct version of Xcode is selected:

```shell-session
sudo xcode-select --switch /Applications/Xcode.app
```

> [!IMPORTANT]
>
> Main branch development of Ghostty requires **Xcode 26 and the macOS 26 SDK**.
>
> You do not need to be running on macOS 26 to build Ghostty, you can
> still use Xcode 26 on macOS 15 stable.

## AI and Agents

If you're using AI assistance with Ghostty, Ghostty provides an
[AGENTS.md file](AGENTS.md)
read by most of the popular AI agents to help produce higher quality
results.

We also provide commands in `.agents/commands` that have some vetted
prompts for common tasks that have been shown to produce good results.
We provide these to help reduce the amount of time a contributor has to
spend prompting the AI to get good results, and hopefully to lower the slop
produced.

- `/gh-issue <number/url>` - Produces a prompt for diagnosing a GitHub
  issue, explaining the problem, and suggesting a plan for resolving it.
  Requires `gh` to be installed with read-only access to Ghostty.

> [!WARNING]
>
> All AI assistance usage [must be disclosed](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md#ai-assistance-notice)
> and we expect contributors to understand the code that is produced and
> be able to answer questions about it. If you don't understand the
> code produced, feel free to disclose that, but if it has problems, we
> may ask you to fix it and close the issue. It isn't a maintainers job to
> review a PR so broken that it requires significant rework to be acceptable.

## Logging

Ghostty can write logs to a number of destinations. On all platforms, logging to
`stderr` is available. Depending on the platform and how Ghostty was launched,
logs sent to `stderr` may be stored by the system and made available for later
retrieval.

On Linux if Ghostty is launched by the default `systemd` user service, you can use
`journald` to see Ghostty's logs: `journalctl --user --unit app-com.mitchellh.ghostty.service`.

On macOS logging to the macOS unified log is available and enabled by default.
Use the system `log` CLI to view Ghostty's logs: `sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'`.

Ghostty's logging can be configured in two ways. The first is by what
optimization level Ghostty is compiled with. If Ghostty is compiled with `Debug`
optimizations debug logs will be output to `stderr`. If Ghostty is compiled with
any other optimization the debug logs will not be output to `stderr`.

Ghostty also checks the `GHOSTTY_LOG` environment variable. It can be used
to control which destinations receive logs. Ghostty currently defines two
destinations:

- `stderr` - logging to `stderr`.
- `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `GHOSTTY_LOG` to `true` will enable all
destinations. Setting `GHOSTTY_LOG` to `false` will disable all destinations.

## Linting

### Prettier

Ghostty's docs and resources (not including Zig code) are linted using
[Prettier](https://prettier.io) with out-of-the-box settings. A Prettier CI
check will fail builds with improper formatting. Therefore, if you are
modifying anything Prettier will lint, you may want to install it locally and
run this from the repo root before you commit:

```
prettier --write .
```

Make sure your Prettier version matches the version of Prettier in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

Nix users can use the following command to format with Prettier:

```
nix develop -c prettier --write .
```

### Alejandra

Nix modules are formatted with [Alejandra](https://github.com/kamadorueda/alejandra/). An Alejandra CI check
will fail builds with improper formatting.

Nix users can use the following command to format with Alejandra:

```
nix develop -c alejandra .
```

Non-Nix users should install Alejandra and use the following command to format with Alejandra:

```
alejandra .
```

Make sure your Alejandra version matches the version of Alejandra in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

### ShellCheck

Bash scripts are checked with [ShellCheck](https://www.shellcheck.net/) in CI.

Nix users can use the following command to run ShellCheck over all of our scripts:

```
nix develop -c shellcheck \
    --check-sourced \
    --severity=warning \
    $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./macos/build/*" ! -path "./.git/*" | sort)
```

Non-Nix users can [install ShellCheck](https://github.com/koalaman/shellcheck#user-content-installing) and then run:

```
shellcheck \
    --check-sourced \
    --severity=warning \
    $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./macos/build/*" ! -path "./.git/*" | sort)
```

### SwiftLint

Swift code is linted using [SwiftLint](https://github.com/realm/SwiftLint). A
SwiftLint CI check will fail builds with improper formatting. Therefore, if you
are modifying Swift code, you may want to install it locally and run this from
the repo root before you commit:

```
swiftlint lint --fix
```

Make sure your SwiftLint version matches the version in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

Nix users can use the following command to format with SwiftLint:

```
nix develop -c swiftlint lint --fix
```

To check for violations without auto-fixing:

```
nix develop -c swiftlint lint --strict
```

### Updating the Zig Cache Fixed-Output Derivation Hash

The Nix package depends on a [fixed-output
derivation](https://nix.dev/manual/nix/stable/language/advanced-attributes.html#adv-attr-outputHash)
that manages the Zig package cache. This allows the package to be built in the
Nix sandbox.

Occasionally (usually when `build.zig.zon` is updated), the hash that
identifies the cache will need to be updated. There are jobs that monitor the
hash in CI, and builds will fail if it drifts.

To update it, you can run the following in the repository root:

```
./nix/build-support/check-zig-cache.sh --update
```

This will write out the `nix/zigCacheHash.nix` file with the updated hash
that can then be committed and pushed to fix the builds.

## Including and Updating Translations

See the [Contributor's Guide](po/README_CONTRIBUTORS.md) for more details.

## Checking for Memory Leaks

While Zig does an amazing job of finding and preventing memory leaks,
Ghostty uses many third-party libraries that are written in C. Improper usage
of those libraries or bugs in those libraries can cause memory leaks that
Zig cannot detect by itself.

### On Linux

On Linux the recommended tool to check for memory leaks is Valgrind. The
recommended way to run Valgrind is via `zig build`:

```sh
zig build run-valgrind
```

This builds a Ghostty executable with Valgrind support and runs Valgrind
with the proper flags to ensure we're suppressing known false positives.

You can combine the same build args with `run-valgrind` that you can with
`run`, such as specifying additional configurations after a trailing `--`.

## Input Stack Testing

The input stack is the part of the codebase that starts with a
key event and ends with text encoding being sent to the pty (it
does not include _rendering_ the text, which is part of the
font or rendering stack).

If you modify any part of the input stack, you must manually verify
all the following input cases work properly. We unfortunately do
not automate this in any way, but if we can do that one day that'd
save a LOT of grief and time.

Note: this list may not be exhaustive, I'm still working on it.

### Linux IME

IME (Input Method Editors) are a common source of bugs in the input stack,
especially on Linux since there are multiple different IME systems
interacting with different windowing systems and application frameworks
all written by different organizations.

The following matrix should be tested to ensure that all IME input works
properly:

1. Wayland, X11
2. ibus, fcitx, none
3. Dead key input (e.g. Spanish), CJK (e.g. Japanese), Emoji, Unicode Hex
4. ibus versions: 1.5.29, 1.5.30, 1.5.31 (each exhibit slightly different behaviors)

> [!NOTE]
>
> This is a **work in progress**. I'm still working on this list and it
> is not complete. As I find more test cases, I will add them here.

#### Dead Key Input

Set your keyboard layout to "Spanish" (or another layout that uses dead keys).

1. Launch Ghostty
2. Press `'`
3. Press `a`
4. Verify that `á` is displayed

Note that the dead key may or may not show a preedit state visually.
For ibus and fcitx it does but for the "none" case it does not. Importantly,
the text should be correct when it is sent to the pty.

We should also test canceling dead key input:

1. Launch Ghostty
2. Press `'`
3. Press escape
4. Press `a`
5. Verify that `a` is displayed (no diacritic)

#### CJK Input

Configure fcitx or ibus with a keyboard layout like Japanese or Mozc. The
exact layout doesn't matter.

1. Launch Ghostty
2. Press `Ctrl+Shift` to switch to "Hiragana"
3. On a US physical layout, type: `konn`, you should see `こん` in preedit.
4. Press `Enter`
5. Verify that `こん` is displayed in the terminal.

We should also test switching input methods while preedit is active, which
should commit the text:

1. Launch Ghostty
2. Press `Ctrl+Shift` to switch to "Hiragana"
3. On a US physical layout, type: `konn`, you should see `こん` in preedit.
4. Press `Ctrl+Shift` to switch to another layout (any)
5. Verify that `こん` is displayed in the terminal as committed text.

## Nix Virtual Machines

Several Nix virtual machine definitions are provided by the project for testing
and developing Ghostty against multiple different Linux desktop environments.

Running these requires a working Nix installation, either Nix on your
favorite Linux distribution, NixOS, or macOS with nix-darwin installed. Further
requirements for macOS are detailed below.

VMs should only be run on your local desktop and then powered off when not in
use, which will discard any changes to the VM.

The VM definitions provide minimal software "out of the box" but additional
software can be installed by using standard Nix mechanisms like `nix run nixpkgs#<package>`.

### Linux

1. Check out the Ghostty source and change to the directory.
2. Run `nix run .#<vmtype>`. `<vmtype>` can be any of the VMs defined in the
   `nix/vm` directory (without the `.nix` suffix) excluding any file prefixed
   with `common` or `create`.
3. The VM will build and then launch. Depending on the speed of your system, this
   can take a while, but eventually you should get a new VM window.
4. The Ghostty source directory should be mounted to `/tmp/shared` in the VM. Depending
   on what UID and GID of the user that you launched the VM as, `/tmp/shared` _may_ be
   writable by the VM user, so be careful!

### macOS

1. To run the VMs on macOS you will need to enable the Linux builder in your `nix-darwin`
   config. This _should_ be as simple as adding `nix.linux-builder.enable=true` to your
   configuration and then rebuilding. See [this](https://nixcademy.com/posts/macos-linux-builder/)
   blog post for more information about the Linux builder and how to tune the performance.
2. Once the Linux builder has been enabled, you should be able to follow the Linux instructions
   above to launch a VM.

### Custom VMs

To easily create a custom VM without modifying the Ghostty source, create a new
directory, then create a file called `flake.nix` with the following text in the
new directory.

```
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    ghostty.url = "github:ghostty-org/ghostty";
  };
  outputs = {
    nixpkgs,
    ghostty,
    ...
  }: {
   nixosConfigurations.custom-vm = ghostty.create-gnome-vm {
     nixpkgs = nixpkgs;
     system = "x86_64-linux";
     overlay = ghostty.overlays.releasefast;
     # module = ./configuration.nix # also works
     module = {pkgs, ...}: {
       environment.systemPackages = [
         pkgs.btop
       ];
     };
    };
  };
}
```

The custom VM can then be run with a command like this:

```
nix run .#nixosConfigurations.custom-vm.config.system.build.vm
```

A file named `ghostty.qcow2` will be created that is used to persist any changes
made in the VM. To "reset" the VM to default delete the file and it will be
recreated the next time you run the VM.

### Contributing new VM definitions

#### VM Acceptance Criteria

We welcome the contribution of new VM definitions, as long as they meet the following criteria:

1. They should be different enough from existing VM definitions that they represent a distinct
   user (and developer) experience.
2. There's a significant Ghostty user population that uses a similar environment.
3. The VMs can be built using only packages from the current stable NixOS release.

#### VM Definition Criteria

1. VMs should be as minimal as possible so that they build and launch quickly.
   Additional software can be added at runtime with a command like `nix run nixpkgs#<package name>`.
2. VMs should not expose any services to the network, or run any remote access
   software like SSH daemons, VNC or RDP.
3. VMs should auto-login using the "ghostty" user.

## Nix VM Integration Tests

Several Nix VM tests are provided by the project for testing Ghostty in a "live"
environment rather than just unit tests.

Running these requires a working Nix installation, either Nix on your
favorite Linux distribution, NixOS, or macOS with nix-darwin installed. Further
requirements for macOS are detailed below.

### Linux

1. Check out the Ghostty source and change to the directory.
2. Run `nix run .#checks.<system>.<test-name>.driver`. `<system>` should be
   `x86_64-linux` or `aarch64-linux` (even on macOS, this launches a Linux
   VM, not a macOS one). `<test-name>` should be one of the tests defined in
   `nix/tests.nix`. The test will build and then launch. Depending on the speed
   of your system, this can take a while. Eventually though the test should
   complete. Hopefully successfully, but if not error messages should be printed
   out that can be used to diagnose the issue.
3. To run _all_ of the tests, run `nix flake check`.

### macOS

1. To run the VMs on macOS you will need to enable the Linux builder in your `nix-darwin`
   config. This _should_ be as simple as adding `nix.linux-builder.enable=true` to your
   configuration and then rebuilding. See [this](https://nixcademy.com/posts/macos-linux-builder/)
   blog post for more information about the Linux builder and how to tune the performance.
2. Once the Linux builder has been enabled, you should be able to follow the Linux instructions
   above to launch a test.

### Interactively Running Test VMs

To run a test interactively, run `nix run
.#check.<system>.<test-name>.driverInteractive`. This will load a Python console
that can be used to manage the test VMs. In this console run `start_all()` to
start the VM(s). The VMs should boot up and a window should appear showing the
VM's console.

For more information about the Nix test console, see [the NixOS manual](https://nixos.org/manual/nixos/stable/index.html#sec-call-nixos-test-outside-nixos)

### SSH Access to Test VMs

Some test VMs are configured to allow outside SSH access for debugging. To
access the VM, use a command like the following:

```
ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p 2222 root@192.168.122.1
ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p 2222 ghostty@192.168.122.1
```

The SSH options are important because the SSH host keys will be regenerated
every time the test is started. Without them, your personal SSH known hosts file
will become difficult to manage. The port that is needed to access the VM may
change depending on the test.

None of the users in the VM have passwords so do not expose these VMs to the Internet.
