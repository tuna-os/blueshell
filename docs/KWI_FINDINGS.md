# What Blueshell can learn from Kwi

Research for [#194](https://github.com/tuna-os/blueshell/issues/194), checked
2026-11-02 against Blueshell `4d8856f3a` and Kwi
[`483d718d779c069a28ec139280d1d6e5e198b94e`](https://invent.kde.org/utilities/kwi/-/tree/483d718d779c069a28ec139280d1d6e5e198b94e).
This is a source review; neither application was built or benchmarked for it.

## Where the comparison applies

Kwi is a KDE terminal using libghostty-vt. Its
[announcement](https://blogs.kde.org/2026/11/01/introducing-kwi/)
describes an experimental project without a tagged v0.1 release. Its performance
numbers compare with Konsole, not Blueshell, and do not establish a performance
gap here.

The useful comparison is how each application connects terminal state to its
desktop. Kwi's [source tree][kwi-root] separates three libraries:

- `ghostty-qt` wraps terminal state and protocol handling.
- `ghostty-qt-quick` renders that state through Qt's scene graph.
- `kwi-terminal` supplies sessions and the public terminal QML module. Both the
  application and the KPart embedding use this module, per the [README][kwi-readme].

Blueshell instead retains Ghostty's renderer and GTK runtime, adding preferences,
profiles and container PTYs. The lesson is to keep those boundaries explicit and
shared. Replacing the runtime with Qt or adopting libghostty-vt as a new backend
would be a separate architectural project, outside this investigation and the
[roadmap's](../ROADMAP.md#deliberately-not-now) current desktop scope.

## Findings and concrete follow-ups

### 1. Audit terminal accessibility before adding more visible features

Kwi's [TerminalAccessible.cpp][kwi-accessible] implements text and action
interfaces, selection offsets, character rectangles and point-to-text lookup.
Its text extraction skips wide-cell tails, distinguishes soft wraps from real
newlines, and caches text using the view's frame revision. These are useful
correctness cases independently of Qt.

Blueshell's [surface widget](../src/apprt/gtk/class/surface.zig) and
[render widget](../src/apprt/gtk/class/render_surface.zig) do not declare a
terminal text accessibility interface. That source observation warrants an
AT-SPI audit; it does not prove what a screen reader can access at runtime.

First follow-up: inspect the terminal with an AT-SPI inspector and Orca on GNOME,
using output containing ASCII, `界`, a combining sequence such as `é`, a wrapped
line and explicit newlines. Record whether text, caret, selection and character
coordinates are available. Select across a wide glyph and a soft wrap, then
resize and repeat. Passing means the reader and copied text agree on logical
characters, without duplicated wide-cell tails or synthetic wrap newlines.
Keep terminal-content coverage separate from accessibility of preference rows.

### 2. Test live theme propagation through to the running TUI

Kwi's [TerminalColors.cpp][kwi-colors] resolves system colors from desktop palette
roles while keeping ANSI colors separate from accent roles. Its
[TerminalView.cpp][kwi-view] applies colors to the session. The transferable
requirement is consistent propagation from desktop preference to terminal and
protocol replies, while preserving an explicitly selected terminal palette.

Blueshell already connects Libadwaita's dark preference to surfaces in
[application.zig](../src/apprt/gtk/class/application.zig), and
[Surface.zig](../src/Surface.zig) queues live color-scheme reports. CSI `?996n`
and mode 2031 are already implemented in
[device_status.zig](../src/terminal/device_status.zig) and
[modes.zig](../src/terminal/modes.zig). They are not missing features to port.

First follow-up: with a light/dark theme pair configured, use a PTY-aware probe
to enable mode 2031 (`ESC [ ? 2031 h`) and query (`ESC [ ? 996 n`). Change GNOME's
dark preference with multiple tabs open. Check the terminal colors and report
against the active scheme, then disable reporting (`ESC [ ? 2031 l`) and verify
that further changes produce no unsolicited reports. Repeat with an explicit
single theme and with a profile override. Restore the desktop preference after
the test. Existing parser tests in
[stream_terminal.zig](../src/terminal/stream_terminal.zig) cover queries; a GTK
interaction check would exercise the desktop-to-surface path they cannot cover.

### 3. Preserve state ownership and measure the existing renderer

Kwi's [Terminal.cpp][kwi-terminal] asserts terminal thread affinity and builds
frames using dirty rows and row versions. [TerminalView.cpp][kwi-view] consumes
snapshots before synchronizing the scene graph. This is a useful reference for
avoiding repeated work and keeping terminal state access on its owning thread.

Blueshell already has a [renderer thread](../src/renderer/Thread.zig) and a
[RenderSurface](../src/apprt/gtk/class/render_surface.zig) that consumes exported
frames via DMABUFs. GPU rendering and separation from the GTK main thread are
existing capabilities. Kwi's design is not evidence that either needs replacing.

First follow-up: measure an idle shell, sustained scrolling and animated images
with visible and hidden tabs. Record commit, workload revision, font, window
size, monitor scale, compositor, GPU/driver, build mode, CPU usage and frame
timings. Compare native and Flatpak builds under identical conditions. Only
change frame scheduling or caching after a profile identifies redundant work;
do not infer battery savings from an FPS comparison.

### 4. Use protocol completeness as a regression matrix

The announcement is a useful list of integration cases, not proof of new parser
work for this fork. Blueshell already parses OSC 5522 and OSC 1337 in
[osc.zig](../src/terminal/osc.zig), and the GTK surface's `setProgressReport`
handles normal, error, indeterminate, paused and removed progress states.
Parsing support alone also does not prove the entire desktop path works.

First follow-up: run progress-state transitions in an existing tab and verify
the overlay, including removal and timeout. Exercise clipboard requests with
allow, deny and ask policies using disposable clipboard contents; the GTK
confirmation path must respect
[Config.zig](../src/config/Config.zig)'s clipboard controls. For image placement,
animation and fractional scaling, compare screenshots after resize and monitor
changes, with selections and ligatures visible. File any observed defect with
the exact escape stream and expected result. Extend upstream-core tests for
parser defects and GTK tests for desktop integration defects.

## Recommended order

Start with the accessibility audit and live-theme interaction check: both probe
behavior that the current [UI smoke test](../TESTING.md) does not assert. Keep
performance work contingent on measurements and protocol work contingent on a
reproducer. These are proposed follow-ups, not verified runtime failures.

This investigation copies no Kwi implementation or assets. Its
[README][kwi-readme] distinguishes library LGPL alternatives from application
GPL alternatives; any future source reuse needs its own license review.

[kwi-root]: https://invent.kde.org/utilities/kwi/-/tree/483d718d779c069a28ec139280d1d6e5e198b94e/libs
[kwi-readme]: https://invent.kde.org/utilities/kwi/-/blob/483d718d779c069a28ec139280d1d6e5e198b94e/README.md
[kwi-accessible]: https://invent.kde.org/utilities/kwi/-/blob/483d718d779c069a28ec139280d1d6e5e198b94e/libs/kwi-terminal/src/TerminalAccessible.cpp
[kwi-colors]: https://invent.kde.org/utilities/kwi/-/blob/483d718d779c069a28ec139280d1d6e5e198b94e/libs/kwi-terminal/src/TerminalColors.cpp
[kwi-view]: https://invent.kde.org/utilities/kwi/-/blob/483d718d779c069a28ec139280d1d6e5e198b94e/libs/kwi-terminal/src/TerminalView.cpp
[kwi-terminal]: https://invent.kde.org/utilities/kwi/-/blob/483d718d779c069a28ec139280d1d6e5e198b94e/libs/ghostty-qt/src/Terminal.cpp
