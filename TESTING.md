# Testing BlueShell

This fork layers a Ptyxis-style UI (preferences window, profiles,
palettes, container integration) on top of upstream Ghostty. Upstream's
own test suite covers the core; **this document covers the fork's test
architecture** — what protects the code we add and change.

## The three lanes

| Lane | What it covers | Where it runs |
| --- | --- | --- |
| **Unit** | Pure logic of the preference UI: widget↔config value mappings, config-file text manipulation, profile snapshot operations | `zig build test`, any machine, no display needed |
| **Integration** | The UI's emitted config parsed back by **Ghostty's real config parser**; full filesystem round-trips in temp dirs | same harness as unit — no mocks, real parser, real files |
| **UI smoke** | The built app starts under Xvfb, loads templates from gresource, survives, and shuts down cleanly | `test/ui/smoke.sh`, CI (`ptyxis-tests.yml`) |
| **Screenshot walkthrough** | PNG captures of the main window and every preferences page for visual review; uploaded as a CI artifact (`ui-walkthrough`) on each run | `test/ui/walkthrough.sh`, CI (`ptyxis-tests.yml`) |

CI for all three lives in `.github/workflows/ptyxis-tests.yml` and runs
on every push to `ptyxis-port` and every PR. The Flatpak build
(`.github/workflows/ghostty-ptyxis.yml`) is the fourth, packaging-level
check.

## Running locally

```sh
# All fork-focused suites (each filter selects one module's tests):
zig build test -Dtest-filter=config_bridge
zig build test -Dtest-filter=profile_store
zig build test -Dtest-filter=preferences_logic

# One test by name:
zig build test "-Dtest-filter=bell features parse"

# UI smoke (needs xvfb-run + dbus-run-session):
zig build && bash test/ui/smoke.sh zig-out/bin/ghostty

# Screenshot walkthrough (adds imagemagick):
bash test/ui/walkthrough.sh zig-out/bin/ghostty test/ui/screenshots
```

The walkthrough drives the preferences window via the
`GHOSTTY_PTYXIS_TEST_PREFS=<page>` startup hook in `application.zig`
(`appearance` / `behavior` / `shortcuts` / `profiles` — the `name:`
properties on the blueprint's `Adw.PreferencesPage`s), so captures are
deterministic without synthetic input events. Review the PNGs (or the
CI artifact) to confirm each page renders its groups and rows.

On systems without a packaged gtk4-layer-shell (e.g. Ubuntu 24.04) add
`-fno-sys=gtk4-layer-shell` so the vendored copy is built.

## Where the tests live and how they're designed

Tests sit next to the code they cover, in fork-owned files — they never
touch upstream files, so they cannot conflict during an upstream rebase:

- **`src/apprt/gtk/class/preferences_logic.zig`** — the single source of
  truth for every ComboRow's index→config-value table and for formatted
  values (`bell-features`, `scroll-to-bottom`, cell-spacing percentages,
  Pango font-description splitting). `preferences_window.zig` calls
  into it; the tests parse every table entry with Ghostty's real parser
  **and check the reverse direction**: every member of the corresponding
  upstream config enum must appear in the table. When upstream adds a
  shell to `shell-integration` or a mode to `window-show-tab-bar`, these
  tests fail — that is the drift alarm, not an inconvenience. Fix by
  adding the new entry to the table *and* to the row's blueprint string
  list.

- **`src/apprt/gtk/class/config_bridge.zig`** — text-level edits of the
  user's config file. Tests cover create/replace/append semantics,
  comment preservation, files without trailing newlines, list-key
  rewrites (`palette`), keybind add/replace/remove — and one
  integration test that writes everything the UI writes and loads it
  with `Config.loadFile`, asserting **zero diagnostics**. If the UI can
  emit a line Ghostty rejects, that test is where it surfaces.

- **`src/apprt/gtk/class/profile_store.zig`** — profile snapshots. Every
  operation has an `*In` variant taking explicit paths; tests run the
  full add → list → switch → update → delete lifecycle against
  `std.testing.tmpDir`, so they are hermetic and parallel-safe. The
  default-named wrappers only resolve XDG paths and delegate.

- **`test/ui/smoke.sh`** — launches the real binary with an isolated
  `XDG_CONFIG_HOME` seeded with the exact keys the preferences UI
  writes, under Xvfb and a private D-Bus session. It catches the class
  of failure unit tests cannot: broken gresource/template bindings,
  missing template children, blueprint/adwaita version mismatches, and
  startup crashes.

## Rules for new preference UI work

1. **New ComboRow?** Add its value table to `preferences_logic.zig`,
   use `logic.comboValue(&table, row.getSelected())` in the handler, and
   add the enum round-trip test. Never inline index→string switches in
   `preferences_window.zig`.
2. **New packed-struct key (feature lists)?** Emit *every* controlled
   flag explicitly (`no-` prefix for off). Ghostty's parser starts from
   the struct **defaults**, not from all-false — omitting a default-on
   feature means the UI can never disable it. Add a parse test proving
   the off state actually turns it off.
3. **New file operation?** Give it an explicit-path variant and a
   tmp-dir test in the same file.
4. **Signal wiring** happens once in `init`, never inside `populate*`
   functions that run repeatedly — reconnecting stacks duplicate
   handlers.
5. Anything that changes what the UI writes must extend the
   `emitted file parses with Ghostty's real config loader` test.

## Known limits

- The smoke test asserts startup health, not interaction. Driving the
  preferences window itself (clicking rows, asserting config writes)
  would need AT-SPI (e.g. dogtail) inside the CI container; the hooks
  are in place (`--gtk-single-instance=false`, isolated XDG dirs) if we
  want to grow that lane.
- Upstream's full `zig build test` suite is not run in fork CI (slow,
  and upstream already gates it); the fork CI still *compiles* the full
  app, so upstream breakage that affects us shows up as a compile error.
