# Contributing to Blueshell

This document describes the process of contributing to Blueshell. It is intended
for anyone considering opening an **issue** or **pull request**.
For technical details and build workflows, please check out our ["Developing Blueshell"](HACKING.md)
guide and ["Testing Blueshell"](TESTING.md) document as well.

> [!NOTE]
>
> Blueshell is an open-source terminal emulator that adapts upstream Ghostty's
> terminal emulation engine and GTK apprt with a Ptyxis-inspired UI, profile system,
> and container integration.
>
> If you are contributing code, fixes, or documentation, please spend a few minutes
> reading this document. Thank you! ❤️

<!-- hive-contribute-plea: donated-compute appeal, keep in sync across repos -->

## Contribute compute — no code needed

**[Donate time with your AI CLI](https://hub.tunaos.org/#contribute).**

Your machine runs one task at a time using your signed-in AI coding CLI.
The relay alternates between eligible **School** (OS) and **Reef** (apps)
hives after each task. If one hive has no work, the other can continue.

The guide covers prerequisites, verified `just` setup, credentials, provider
costs, and how to stop with Ctrl+C. Your subscription quota or API charges apply.
Never post account credentials or API keys in issues or pull requests.

## The Critical Rule

**The most important rule: you must understand your code.** If you can't
explain what your changes do and how they interact with the greater system
without the aid of AI tools, do not contribute to this project.

Using AI to assist in writing code is fine, but you must thoroughly understand
and verify all code you submit. What's not fine is submitting unverified or
poorly understood agent-generated code without taking responsibility for the
changes. Please review the [AI Usage Policy](AI_POLICY.md).

## Upstream Relationship (Ghostty & Ptyxis)

Blueshell is developed in `tuna-os/blueshell` on the `ptyxis-port` integration branch:

- **Upstream Ghostty**: Blueshell layers its GTK / Libadwaita interface on top of Ghostty's
  Zig terminal core. For details on how we track and rebase upstream Ghostty changes,
  see [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md) and [CONFLICT_HOTSPOTS.md](CONFLICT_HOTSPOTS.md).
- **Issue Tracker & Pull Requests**: All issues, feature requests, bug reports, and pull
  requests for Blueshell belong in the **[tuna-os/blueshell issue tracker](https://github.com/tuna-os/blueshell/issues)**.
  Do **not** report Blueshell bugs or submit Blueshell PRs to upstream `ghostty-org/ghostty` or `chergert/ptyxis`.
- **Target Branch**: All pull requests must target the `ptyxis-port` branch.

## Quick Guide

### I'd like to contribute

Check out the [open issues](https://github.com/tuna-os/blueshell/issues) on GitHub.
Pick an issue that interests you, comment to let others know you are looking into it,
and open a pull request once you have a tested solution.

### I have a bug! / Something isn't working

1. First, search the [Blueshell issue tracker](https://github.com/tuna-os/blueshell/issues)
   (both open and closed issues) to see if the problem has already been reported or solved.
2. If your issue hasn't been reported yet, open a new issue in `tuna-os/blueshell`.
3. Fill in reproduction steps, expected behavior, terminal output or logs, and system details
   (OS distribution, desktop environment/compositor, GPU driver, package format like Flatpak or native build).

### I have an idea for a feature

1. Search existing issues to ensure the feature isn't already planned or discussed.
2. Open an issue describing the proposed feature, the use case, and how it aligns
   with Blueshell's container-first, GNOME/Libadwaita terminal experience.

### I'd like to translate Blueshell

We welcome localization improvements. See [po/README_TRANSLATORS.md](po/README_TRANSLATORS.md)
for instructions on updating gettext catalogs. Make sure translations follow the
project's style guide and can be compiled cleanly with gettext tools.

## Development and Testing Workflow

Before opening a pull request, ensure your code compiles and passes local tests and formatting checks.

### Building

Blueshell requires Zig 0.15.x and GTK4 / Libadwaita development packages. You can build natively or within a Fedora toolbox:

```sh
# Build GTK application (debug)
zig build -Dapp-runtime=gtk

# Fast release build
zig build -Dapp-runtime=gtk -Doptimize=ReleaseFast
```

See [HACKING.md](HACKING.md) for full developer environment setup (Fedora toolbox, dependencies, flags).

### Testing

Blueshell maintains automated tests across unit, integration, and UI smoke lanes:

```sh
# Run targeted test suites
zig build test -Dtest-filter=config_bridge
zig build test -Dtest-filter=profile_store
zig build test -Dtest-filter=preferences_logic

# Run a specific test
zig build test -Dtest-filter="<test name>"
```

For UI smoke tests and screenshot walkthrough testing (using Xvfb), see [TESTING.md](TESTING.md).

### Code Formatting

Please format your changes before submitting:

- **Zig**: `zig fmt .`
- **Swift** (macOS, if applicable): `swiftlint lint --strict --fix`
- **Other files (JSON, Markdown, YAML)**: `npx prettier -w .`

## Pull Request Guidelines

1. **Base Branch**: Ensure your branch is branched from and opened against `upstream/ptyxis-port`.
2. **Commit Messages**: Follow Conventional Commits format (e.g. `feat: ...`, `fix: ...`, `docs: ...`, `chore: ...`).
3. **Signed-off-by Trailer**: Every commit must carry a Developer Certificate of Origin (DCO) sign-off (`git commit -s`).
4. **Issue References**: Link the relevant issue in your pull request description using GitHub keywords (e.g. `Closes #123` or `Fixes #123`).
5. **Continuous Integration**: Ensure CI checks (build, test, formatting) pass on your pull request.
