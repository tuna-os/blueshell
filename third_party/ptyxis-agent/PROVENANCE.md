# Vendored `ptyxis-agent` Provenance and Contract

## Upstream Provenance

- **Upstream Project**: [Ptyxis](https://gitlab.gnome.org/chergert/ptyxis) (GNOME / Christian Hergert)
- **Component**: `agent/` subdirectory from upstream Ptyxis
- **Upstream Repository**: `https://gitlab.gnome.org/chergert/ptyxis.git`
- **Upstream Release Tag**: `49.0`
- **Upstream Commit**: `1dc93d0d80ce3e482d5c3d06dc4534bd266ac1a3`
- **Import Date**: June 4, 2026 (imported in Blueshell commit `10fe6b6284c6bc0594084a6070d1eb5cc5eeaa01`)
- **Authoritative SPDX License**: `GPL-3.0-or-later` (matching upstream Ptyxis's `COPYING` and source file headers)

## Architectural Boundary and Role

`ptyxis-agent` is the host-side agent responsible for discovering container and virtual machine environments and brokering PTY handoff.

- **Communication Mechanism**: Blueshell communicates with `ptyxis-agent` through a private UNIX socketpair via GDBus (`/org/gnome/Ptyxis/Agent`, implementing D-Bus interface `org.gnome.Ptyxis.Agent` defined in `org.gnome.Ptyxis.Agent.xml`). The agent is invoked with `--socket-fd=N` and does not connect to the system or session message buses.
- **Runtime Resolution**: Blueshell locates the agent executable using:
  1. `PTYXIS_AGENT` or `PTYXIS_AGENT_PATH` environment variables.
  2. `/app/libexec/ptyxis-agent` (Flatpak bundle location).
  3. Sibling binary to the `ghostty` executable or build tree location.

## Local Modifications

The following changes diverge from upstream Ptyxis `agent/`:

1. **Standalone Build System (`meson.build`)**:
   Upstream builds `agent/` as part of the overall Ptyxis application. We maintain a standalone `meson.build` and minimal `config.h` so the agent compiles independently without GTK or Ptyxis UI dependencies. An unmodified reference copy of upstream's build definition is preserved as `meson.build.upstream`.

2. **VM and Cluster Provider Extensions (`blueshell-vm-providers.c`, `blueshell-vm-providers.h`)**:
   Adds opt-in discovery of VM and cluster shell targets enabled via `BLUESHELL_VM_PROVIDERS` (e.g. Lima, Incus, Libvirt, Kubernetes, KubeVirt, Corral).

3. **Hook in `ptyxis-agent.c`**:
   - Includes `blueshell-vm-providers.h` and calls `blueshell_vm_providers_enumerate` during `ptyxis_agent_init`.
   - Maps `manager=apx` to `PTYXIS_TYPE_DISTROBOX_CONTAINER`.
   - Guards `main()` with `#ifndef DISABLE_AGENT_ENTRY_POINT` so test harnesses can link against agent logic.

4. **VM Provider Test Suite (`test-vm-providers.c`)**:
   Unit test harness executing mock CLI shims on `PATH` to verify provider JSON and table parsing in CI without requiring live VMs or clusters.

5. **Distrobox TTY and Unshared Groups Handling (`ptyxis-distrobox-container.c`)**:
   Implements `ptyxis_distrobox_container_deserialize` to detect the `distrobox.unshare_groups` label (`#477`, `#545`) and adjust `--no-tty`/`--tty` arguments accordingly.

6. **Podman Container Helper and JSON Parsing (`ptyxis-podman-container.{c,h}`, `ptyxis-podman-provider.c`, `ptyxis-podman-provider-private.h`)**:
   Exposes `ptyxis_podman_container_lookup_label` and separates `_ptyxis_podman_provider_parse_json` for container inspection and unit testing.

7. **Enterprise Linux glibc Linkage Compatibility (`libc-compat.h`, `ptyxis-agent-compat.h`, `x86_64/force_link_glibc_2.17.h`)**:
   Preserves older GLib/glibc symbol linkage compatibility for CentOS 7 / enterprise Linux environments when built with `libc-compat`.

## Maintenance and Re-vendoring Procedure

When updating `third_party/ptyxis-agent` from a newer upstream Ptyxis release:

1. Check out the target upstream tag or commit in a clone of `https://gitlab.gnome.org/chergert/ptyxis.git`.
2. Diff upstream `agent/` against `third_party/ptyxis-agent/` (excluding Blueshell additions: `blueshell-vm-providers.*`, `test-vm-providers.c`, `PROVENANCE.md`).
3. Copy updated files from upstream `agent/`.
4. Inspect any upstream changes to `agent/meson.build`, update `meson.build.upstream` to match, and adjust `meson.build` as necessary.
5. Ensure the `blueshell_vm_providers_enumerate` hook in `ptyxis-agent.c` and the podman/distrobox helpers remain intact.
6. Verify the build and test suite pass:
   ```bash
   meson setup build third_party/ptyxis-agent
   meson test -C build --print-errorlogs
   ```
7. Update this file (`PROVENANCE.md`) with the new upstream tag, commit SHA, and any changes in local patches.
