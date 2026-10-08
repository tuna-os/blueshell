# Vendored `ptyxis-agent` Provenance and Maintenance Contract

## Upstream Provenance

- **Upstream Project**: [Ptyxis](https://gitlab.gnome.org/chergert/ptyxis) (GNOME / Christian Hergert)
- **Component**: `agent/` subproject from upstream Ptyxis
- **Import Target**: `version: '49.0'`, imported around June 2026 (commit `10fe6b6284c6bc0594084a6070d1eb5cc5eeaa01`)
- **Upstream Repository**: `https://gitlab.gnome.org/chergert/ptyxis.git`
- **License**: `GPL-3.0-or-later` (Christian Hergert and Ptyxis contributors)

## Role in BlueShell

`ptyxis-agent` runs on the host to discover running container environments (Toolbox, Distrobox, Podman) as well as opt-in VM/cluster environments (Lima, Incus, Libvirt, Kubernetes, KubeVirt, Corral). It communicates with BlueShell's Zig UI process via a private UNIX socketpair using GDBus (`/org/gnome/Ptyxis/Agent`, implementing interface `org.gnome.Ptyxis.Agent`).

BlueShell locates the agent at runtime via:
1. `PTYXIS_AGENT` or `PTYXIS_AGENT_PATH` environment variables
2. `/app/libexec/ptyxis-agent` (Flatpak bundle location)
3. Sibling binary to the `ghostty` executable or build tree location

## Local Modifications

To maintain maintainability and support re-vendoring, local patches against upstream Ptyxis `agent/` are documented here:

1. **Standalone Build System (`meson.build`)**:
   Upstream builds the agent as part of the overall Ptyxis Meson project. We maintain a standalone `meson.build` and minimal `config.h` so the agent compiles independently without requiring Ptyxis GUI dependencies. `meson.build.upstream` is preserved as a reference copy of the original upstream build definition.

2. **VM and Cluster Provider Extension (`blueshell-vm-providers.c`, `blueshell-vm-providers.h`)**:
   Adds opt-in discovery of VM and cluster shell targets enabled via `BLUESHELL_VM_PROVIDERS` (e.g. `corral`, `lima`, `incus`, `libvirt`, `kubernetes`, `kubevirt`). Hooks into `ptyxis_agent_init` in `ptyxis-agent.c`.

3. **VM Provider Test Suite (`test-vm-providers.c`)**:
   Unit test harness executing mock CLI shims on `PATH` to verify provider JSON and table parsing in CI without requiring live VMs.

4. **glibc Compatibility Stub (`libc-compat.h`, `x86_64/force_link_glibc_2.17.h`)**:
   Preserves compatibility with enterprise distributions when built with `libc-compat`.

## Re-vendoring / Sync Procedure

When updating `third_party/ptyxis-agent` from a newer upstream Ptyxis release:
1. Checkout the target upstream tag or commit in a clone of `gitlab.gnome.org/chergert/ptyxis`.
2. Diff upstream `agent/` against `third_party/ptyxis-agent/` excluding `blueshell-vm-providers.*` and `test-vm-providers.c`.
3. Copy new or updated files from upstream `agent/`.
4. Inspect changes to upstream `agent/meson.build` and update `meson.build.upstream` and `meson.build` accordingly.
5. Verify the hook in `ptyxis-agent.c` (calling `blueshell_vm_providers_enumerate`) is preserved.
6. Run `meson setup build && ninja -C build test` to verify `test-vm-providers`.
7. Update this document with the new upstream release tag / commit SHA and import date.
