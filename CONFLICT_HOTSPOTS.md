# Upstream Rebase Hotspots

This file lists every upstream Ghostty file we modify in `ptyxis-port`,
what we changed, and why. When `upstream-sync` flags a conflict in one
of these files, this is your map.

If a file isn't listed here, our changes there are additions in new
locations and conflict only by coincidence — read the diff.

**Scope.** This map covers upstream files under `src/`, plus
`.gitignore`. The fork also patches twelve upstream workflows under
`.github/workflows/` and two upstream docs (`README.md`, `HACKING.md`);
those conflict on rebase like anything else, and whether they belong in
this map is an open question — see issue #55.

When upstreaming a hotspot makes a downstream patch unnecessary
(issue #6 is the canonical example), delete the entry from this file
in the same commit that drops the patch.

---

## `src/termio/Exec.zig` — HIGH risk

**What we changed:**

- Extracted the PTY stream, reader-thread, and termios-timer setup into
  `threadEnterPty`, shared by the exec and adopt backends.
- Added shared PTY lifecycle helpers for thread exit, focus changes, and
  queued writes. Thread-local data lookup accepts both backend tags.
- Kept subprocess creation and process watching exclusively in `Exec`;
  adopted descriptors no longer add state or branches to `Subprocess`.

**Why it can break:** upstream frequently changes the read pipeline,
`ThreadData`, or `Exec.threadEnter`. Those changes must remain common to
both PTY-backed backends without moving subprocess state into adopt mode.

**Resolution recipe:** preserve upstream's latest post-spawn PTY setup,
then keep `threadEnterPty` as the single initialization path used after
`Subprocess.start` and by `Adopt.threadEnter`. Keep process-watch setup in
`Exec.threadEnter` only.

**Upstreaming:** issue #6.

---

## `src/termio/backend.zig` — HIGH risk

**What we added:** the `.adopt` backend and thread-data variants. `Adopt`
owns an externally-created PTY master, applies terminal resizes, and uses
the shared Exec PTY read/write lifecycle without creating or watching a
subprocess.

**Why it can break:** every new upstream backend method or exhaustive
switch must define adopt behavior too.

**Resolution recipe:** retain the `.adopt` variants and delegate
PTY-only operations to the shared helpers in `Exec.zig`. Process
inspection uses the owned PTY; abnormal child-exit handling remains
exec-only.

---

## `src/Surface.zig` — MEDIUM risk

**What we added:** queries `rt_surface.externalMasterFd()` via
`@hasDecl`. When present, it selects the `.adopt` backend directly;
otherwise it builds the normal `Exec` backend and subprocess environment.

**Why it can break:** upstream changes backend initialization in
`Surface.init` or adds backend-dependent child-exit reporting.

**Resolution recipe:** preserve the backend selection before
`Termio.init`. The external fd goes only into `Adopt.Config`; never add it
back to `Exec.Config`.

---

## `src/apprt/embedded.zig` — LOW risk

**What we added:** stub `externalMasterFd(*const Surface) ?c_int` that
returns `null`. Two lines.

**Why it can break:** unlikely. Only conflicts if upstream adds a method
with the same name immediately above `defaultTermioEnv`.

---

## `src/apprt/gtk/Surface.zig` — LOW risk

**What we added:** wrapper `externalMasterFd` delegating to the class
implementation.

**Resolution recipe:** add the wrapper next to `defaultTermioEnv`.

---

## `src/apprt/gtk/class/surface.zig` — LOW risk

**What we added:** `externalMasterFd` calls
`Application.default().takePendingExternalMasterFd()`. Foreground-agent
detection also reads the PTY master directly from the adopt backend.

---

## `src/apprt/gtk/class/application.zig` — HIGH risk

**What we changed:**

- New imports: `ContainerClient`, `Container`, `palette_mod`,
  `preferences_window`, `config_bridge`.
- Private struct gains: `container_client`, `container_model`,
  `pending_external_master_fd`, `pending_container_title`,
  `pending_container_icon`.
- New methods: `containerModel`, `containerClient`,
  `setPendingExternalMasterFd` / `takePendingExternalMasterFd`,
  `setPendingContainerTabMetadata` /
  `takePendingContainerTabTitle` / `takePendingContainerTabIcon`,
  `startupContainerClient`, `resolveAgentPath`.
- Startup hook to call `startupContainerClient` so the agent is
  reachable before any window opens.
- New actions: `preferences`.
- Smoke-test env hooks (`GHOSTTY_PTYXIS_TEST_*`).
- Force-analysis comptime block listing all `ContainerClient` methods
  we want eagerly analyzed.

**Why it can break:** upstream churns the actions array, the Private
struct, the startup sequence, and Ghostty-action handlers all
independently. Every release tends to touch this file.

**Resolution recipe:** treat the conflict as additions. Our entries
in the actions array are NEW names; if upstream renamed an existing
action ours still apply unchanged. Our Private struct additions go at
the end of the struct after upstream's fields. Smoke-test envs and
the comptime block are leaf additions — keep them.

---

## `src/apprt/gtk/class/window.zig` — HIGH risk

**What we changed:**

- Imports for `Container`, `gio`, `glib` already exist upstream — no
  new imports.
- Private struct gains `new_tab_button`, `new_tab_button_compact`
  template-child bindings (existing widgets we needed to grab).
- Actions array gains `new-tab-in-container`, `set-theme`, `zoom-in`,
  `zoom-out`, `zoom-reset`.
- `refreshContainerMenu` builds a Gio.Menu from
  `Application.containerModel` and sets it on both split buttons.
- `spawnInContainerById` + `actionNewTabInContainer` + helpers
  (`PtsLibc` extern block, `smokeSpawnInContainer`).
- After `performBindingAction(.new_tab)` in
  `actionNewTabInContainer`, we apply the pending container title +
  icon to the freshly-selected `Adw.TabPage`.

**Why it can break:** upstream redesigns the new-tab dropdown, the
actions array, or the action wiring.

**Resolution recipe:** new actions in the array are additions. The
container-spawn logic is self-contained at the end of the file —
move it as a block if upstream restructured. The
`performBindingAction(.new_tab)` → `getSelectedPage` → setTitle/setIcon
sequence depends on `tab_view.setSelectedPage(page)` being called
synchronously by `newTabPage` (line ~484 currently). If upstream makes
new-tab async, this will need a signal handler on
`tab_view::page-attached`.

---

## `src/apprt/gtk/ui/1.5/window.blp` — MEDIUM risk

**What we changed:**

- Both compact and full `Adw.SplitButton`s for new-tab gained `id`
  attributes (`new_tab_button`, `new_tab_button_compact`).
- `main_menu` rewritten: added Theme section (3 items), Zoom section
  (3 items). The original sections (New Tab/Window, Tab Overview,
  Fullscreen, Preferences/Shortcuts/About) are preserved below.

**Why it can break:** upstream restyles the header or the menu.

**Resolution recipe:** add our Theme and Zoom sections to whatever
new menu structure upstream produced; keep the SplitButton IDs.

---

## `src/apprt/gtk/build/gresource.zig` — LOW risk

**What we added:** one entry `.{ .major = 1, .minor = 5, .name =
"preferences-window" }` so the build bundles our blueprint.

**Resolution recipe:** add the line. The build script reads this list
and finds the corresponding `ui/1.5/preferences-window.blp`.

---

## `src/termio/message.zig` + `src/termio/Thread.zig` — LOW risk

**What we added:** an `inject_output: WriteReq.Alloc` message variant
(message.zig) and its handler in the Thread message switch
(Thread.zig): free the buffer, call `io.processOutput(v.data)`. Used by
the per-tab palette OSC injection (`osc_palette.zig`).

**Why it can break:** upstream reshapes the Message union or the
Thread dispatch switch.

**Resolution recipe:** re-add the variant next to the `write_*`
members and the handler case next to `.write_alloc`; the handler body
is three lines and only depends on `processOutput` staying public.

**Upstreaming:** could ride along with issue #6's discussion — a
parser-injection message is broadly useful for embedders.

---

## `src/config/Config.zig` + `src/config.zig` — HIGH risk

**What we added:**

- `@"exit-action": ExitAction = .close` and the `ExitAction` enum, plus
  the `pub const ExitAction = Config.ExitAction;` re-export in
  `src/config.zig`.
- `@"agent-detect": RepeatableString`, `@"agent-notify": bool`,
  `@"agent-colors": bool` — the RFC #22 agent-awareness options.
- **A changed upstream default:** `@"window-theme"` was `.auto`, we ship
  `.system`, together with the rewritten doc comment above it.
- **Flatpak host config.** `loadDefaultFiles` now calls
  `loadFlatpakHostFiles` first (new fn right after it) and the
  template-creation check reads `!xdg_loaded and !host_loaded`. The
  logic lives in the new file `src/config/flatpak_host.zig`, imported
  as `flatpak_host` at the top of `Config.zig`.

**Why it can break:** `Config.zig` is upstream's central config struct
and one of the files upstream edits most often. Worse, the
`window-theme` patch is a *modification*, not an addition: a rebase can
drop it without producing a conflict at all. Upstream keeps `.auto`,
our line is gone, nothing fails, and the app silently stops following
the desktop light/dark preference.

**Resolution recipe:** the three additions are order-insensitive struct
fields — re-add them anywhere in the field list, keeping the doc
comments. Then explicitly re-check `@"window-theme"`: it must read
`.system`. Verify with `grep -n 'window-theme' src/config/Config.zig`
after every rebase, whether or not the file conflicted.

If `loadDefaultFiles` conflicts: keep upstream's body, then re-add the
`const host_loaded = try self.loadFlatpakHostFiles(alloc);` line before
the XDG load and the `and !host_loaded` in the non-macOS template
branch. Without it the Flatpak build silently stops reading
`~/.config/ghostty` (issue #117) — no compile error, no test failure
outside Flatpak.

---

## `src/config/theme.zig` — LOW risk

**What we added:** a `host_user` member of `Location` (between `user`
and `resources`; enum order is search priority), its `dir()` branch, and
the `flatpak_host` import. Lets user themes in the host's
`~/.config/ghostty/themes` resolve inside Flatpak.

**Resolution recipe:** re-add the enum member in that position and the
`.host_user` switch arm. `list_themes.zig` needs no change.

---

## `src/termio/shell_integration.zig` — HIGH risk

**What we added:** a `host_resource_dir: ?[]const u8` parameter on the
public `setup()` signature, threaded into `setupBash`, `setupZsh`,
`setupNushell`, and `setupXdgDataDirs` (fish/elvish) as a non-optional
`host_resource_dir: []const u8`. In each, the in-sandbox `resource_dir`
is used for the file-existence check and `host_resource_dir` for the
env value (`ENV`, `ZDOTDIR`, `XDG_DATA_DIRS`) — a Flatpak-only split,
because the subprocess may run outside the sandbox and needs a
host-accessible path. Without it the host shell can't find the
integration files; for zsh it is worse, since a bad `ZDOTDIR` makes zsh
skip the user's `~/.zshrc` entirely (issue #117 follow-up). The direct
unit tests pass the same dir twice; `zsh: host resources dir` and
`xdg: host resources dir` cover the split.

**Why it can break:** we changed a public function's parameter list, so
every upstream call site of `setup()` is a patch of ours too. Any
upstream change to `setup()`, `setupBash`, or the resource-dir plumbing
collides.

**Resolution recipe:** re-add the optional parameter last on `setup()`,
pass `host_resource_dir orelse resource_dir` down to all four helpers,
and keep the check-path/env-path split inside each. Fix up upstream
call sites and the in-file tests (same dir twice, plus the two
host-path tests).

**2026-10 upstream Io refactor:** upstream replaced `std.fs.*` file APIs
with `std.Io.Dir.*(global.io(), …)`, `EnvMap` with
`std.process.Environ.Map`, and deleted `src/os/env.zig`. Our
`setupBash`/`setupZsh`/`setupXdgDataDirs` splits had to be re-expressed
on the new calls (`openFileAbsolute`/`openDirAbsolute` take `global.io()`
first, `close` takes it too, `env.remove` is now
`env.swapRemove`); the new fork files `profile_store.zig`,
`config_bridge.zig`, and `flatpak_host.zig` needed the same port and —
being new files — never conflicted, so they fail at compile time
instead. After any rebase, grep fork-owned files for
`std.fs.openFileAbsolute`, `std.fs.max_path_bytes`, `getEnvMap`, and
`os/env.zig` imports. (Also: 0.16 `zig fmt` rejects a trailing `;`
after an if/else statement.)

**Upstreaming:** a sandbox-aware resource dir is not BlueShell-specific
— Ghostty's own Flatpak build has the same problem. Worth an upstream
issue.

---

## `src/apprt/gtk/class/tab.zig` + `src/apprt/gtk/ui/1.5/tab.blp` — MEDIUM risk

**What we added:**

- A `title-prefix` property on `Tab` (Ptyxis-style, e.g. a container
  name followed by " · "), prepended to the computed title unless a
  title override is set.
- The agent-state badge: per-tab idle / working / blocked / done
  indicator, its icons, and the needs-attention pulse (RFC #22).
- `tab.blp` threads `template.title-prefix` into the `computed_title`
  bind expression's argument list.

**Why it can break:** upstream reshapes `computed_title` or its bind
arguments; the `.blp` bind list is positional, so an upstream argument
added or removed silently changes what our prefix binds to.

**Resolution recipe:** re-add the property and the badge, then check
the `computed_title` bind in `tab.blp` argument by argument against the
Zig signature — a mismatch here compiles and fails at runtime.

---

## `src/apprt/gtk/class.zig` — LOW risk

**What we added:** one re-export line,
`pub const ContainerClient = @import("class/container_client.zig").Client;`

**Resolution recipe:** re-add the line next to the other class
re-exports.

---

## `.gitignore` — LOW risk

**What we added:** `zig-pkg/` to keep the vendored package cache out
of commits.

## `build.zig.zon` — LOW risk

**What we changed:** `.version` is ours, not upstream's. It must equal
the `vX.Y.Z` release tag exactly — the build panics on tagged builds
otherwise. Upstream bumps it on their own cadence (`1.3.2-dev`, …);
we set it deliberately per BlueShell release (currently `1.3.1`, the
Ghostty release we match).

**Resolution recipe:** on conflict, keep OUR `.version` line. Never take
upstream's `-dev` version, or the next tagged Flatpak build aborts.
(`minimum_zig_version` is upstream's to bump — take theirs.)
---

## Files we DON'T touch (assert this on rebase)

- `src/main.zig`
- `src/build.zig`
- Anything in `src/terminal/`, `src/font/`, `src/renderer/`
- `src/input/`

`src/config/` used to be on this list. It is not true and has not been
since `40068cc` — see the `Config.zig` hotspot above. The entry is kept
here as a note rather than deleted silently, because a resolver who
remembers the old rule needs to be told it changed.

If upstream-sync produces conflicts in any of those, something is
wrong — either an accidental edit, or upstream refactored a callee we
depend on. Investigate before resolving.
