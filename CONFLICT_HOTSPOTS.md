# Upstream Rebase Hotspots

This file lists every upstream Ghostty file we modify in `ptyxis-port`,
what we changed, and why. When `upstream-sync` flags a conflict in one
of these files, this is your map.

If a file isn't listed here, our changes there are additions in new
locations and conflict only by coincidence — read the diff.

When upstreaming a hotspot makes a downstream patch unnecessary
(issue #6 is the canonical example), delete the entry from this file
in the same commit that drops the patch.

---

## `src/termio/Exec.zig` — HIGH risk

**What we added:**

- `Config.external_master_fd: ?Pty.Fd = null` and the matching field on
  `Subprocess`.
- An early branch at the top of `Subprocess.start`: if
  `external_master_fd` is set, wrap it in a `Pty{ master, slave = -1 }`,
  set the size, and return the fd as both read and write. Skip the
  `Pty.open` + fork path entirely.
- In `Exec.threadEnter`, the `else return error.ProcessNotStarted`
  branch now also accepts a null process when `external_master_fd` is
  set (we have a pty but no child to watch — the child is the agent's).

**Why it can break:** upstream restructures `Subprocess.start` or
`Process` union. Today's branch is at the top of `start` and is easy
to re-port; if it moved into a different control flow, re-do it.

**Resolution recipe:** find the new shape of `Subprocess.start`, drop
the adopt branch at the earliest point after `assert(pty == null and
process == null)`. Ensure `threadEnter` still tolerates null process.

**Upstreaming:** issue #6.

---

## `src/Surface.zig` — MEDIUM risk

**What we added:** queries `rt_surface.externalMasterFd()` via
`@hasDecl` and threads the result into `termio.Exec.Config`.

**Why it can break:** upstream changes the `Exec.Config` literal in
`Surface.init`.

**Resolution recipe:** the addition is a single field
`.external_master_fd = external_master_fd` inside the `termio.Exec.init`
config struct, plus the `external_master_fd` local computed above.
Place anywhere — `Config` is order-insensitive.

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

**What we added:** `externalMasterFd` method that calls
`Application.default().takePendingExternalMasterFd()`.

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

## `.gitignore` — LOW risk

**What we added:** `zig-pkg/` to keep the vendored package cache out
of commits.

---

## Files we DON'T touch (assert this on rebase)

- `src/main.zig`
- `src/build.zig`
- Anything in `src/terminal/`, `src/font/`, `src/renderer/`
- Anything in `src/config/` (we read it, never modify)
- `src/input/`

If upstream-sync produces conflicts in any of those, something is
wrong — either an accidental edit, or upstream refactored a callee we
depend on. Investigate before resolving.
