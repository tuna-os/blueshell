# NSL terminal provider evaluation

Status: **not implemented**. This is a compatibility investigation for
[#182](https://github.com/tuna-os/blueshell/issues/182), not evidence that
BlueShell supports NSL. A live NSL machine and both native and Flatpak UI paths
still need to be tested before shipping a provider.

## Initial probe

The investigation environment had no installed `nsl`, Flatpak, Podman, C
compiler or Meson, and no `/dev/kvm`. To get a small CLI probe anyway, NSL
[v0.11.0](https://github.com/frostyard/nsl/tree/436167b05af0e7389f1a257425ef96038b54d5d2)
(commit `436167b05af0e7389f1a257425ef96038b54d5d2`) was built from source
with `go build -o /tmp/issue182-nsl-probe .`. The source build's `version`
reported `vmspawn-dev` (the release version is normally injected at build
time); its `help` advertised `list --json` and `run -m NAME --cd PATH`.
With a temporary `HOME` and `NSL_HOME`, `list --json` failed with
`mkdir /run/user: permission denied`, and `doctor` reported missing
systemd-vmspawn, QEMU, virtiofsd, KVM and a user systemd session. No JSON
response or terminal-in-machine behavior was observed. This is not a test of
an installed NSL release or a working machine.

On a suitable host, first record the installed version and check the actual
response (machine names and paths may be private; redact them before sharing):

```sh
command -v nsl
nsl version
nsl doctor
nsl list --json
```

On Flatpak, perform the equivalent host-side check **from the sandbox** with
`flatpak-spawn --host nsl version` and `flatpak-spawn --host nsl list --json`.
A host terminal running `flatpak-spawn` alone is not a sandbox test. Compare
the visible machines and effective `NSL_HOME`/`XDG_DATA_HOME` in the actual
agent environment; do not assume the sandbox PATH or data directory is the
host's. An absent CLI, nonzero exit, timeout, or malformed output is not an
empty successful inventory.

## Interface and lifecycle findings

The versioned [NSL CLI contract](https://github.com/frostyard/nsl/blob/436167b05af0e7389f1a257425ef96038b54d5d2/docs/specs/cli.md#machine-readable-output)
and [ADR-0021](https://github.com/frostyard/nsl/blob/436167b05af0e7389f1a257425ef96038b54d5d2/docs/adr/0021-machine-readable-output.md)
specify a JSON object with a `machines` array, not JSON lines. Each record
has a name, state, image, tier and default marker; consumers must ignore
unknown fields. The contract lists `running`, `starting`, `stopping`,
`stopped`, `incomplete` and `removing`. Igloo's
[provider](https://github.com/frostyard/igloo/blob/38d98cd171d4ffbbe4adfaa55818f503206866dd/agent/ptyxis-nsl-provider.c)
excludes `incomplete` and `removing`, but retains stopped machines because
entering them can start them. A future adapter should validate required
fields and names, and conservatively exclude unknown or malformed states;
verify these choices against the installed version rather than treating
unrecognized output as an authoritative empty list.

Igloo also watches the per-user state directories and runtime changes,
coalesces updates, and preserves the container object for a machine that
remains present. It schedules follow-up refreshes after a spawn instead of
continuous polling, which could interfere with idle shutdown. Its
[container implementation](https://github.com/frostyard/igloo/blob/38d98cd171d4ffbbe4adfaa55818f503206866dd/agent/ptyxis-nsl-container.c)
uses host `nsl run -m NAME --cd / -- ...`, carries the PTY, and runs a guest
wrapper to choose a usable working directory and shell. NSL has shared and
isolated tiers; a host path is not automatically available in an isolated
machine. Guest environment, shell lookup and URI/directory translation need
explicit handling, not merely a command prefix. `NSL_HOME` defaults to
`$XDG_DATA_HOME/nsl` (normally `~/.local/share/nsl`); NSL v0.11.0 uses
`/run/user/UID/nsl` for runtime state. Monitors must also handle directories
created after startup and sandbox visibility; they are notifications to reload,
not the authoritative machine list.

## BlueShell integration assessment

- `third_party/ptyxis-agent/blueshell-vm-providers.c` and its only production
  caller in `ptyxis-agent.c` enumerate opt-in VM providers once at startup.
  `PtyxisSessionContainer` applies a host command prefix, host-side cwd and
  shell lookup. This alone cannot provide the lifecycle and guest semantics
  above. Leave existing providers unchanged and make NSL opt-in via
  `BLUESHELL_VM_PROVIDERS`.
- A dedicated `PtyxisContainerProvider` registered with
  `ptyxis_agent_impl_add_provider()` can emit additions/removals. Use a
  stable, provider-prefixed machine ID for restore and retain the same exported
  object for an unchanged ID. The generic `ptyxis_container_provider_merge()`
  replaces objects for equal IDs without re-exporting them, so it is not by
  itself the required identity-preserving merge. Serialize or generation-tag
  async list requests so an older response cannot undo a newer one; retain the
  last good model on command/parse failures and remove entries only from a
  successful authoritative list.
- The GTK `container_client.zig` obtains an initial list and
  `application.zig` caches it. `window.zig` builds its menu from that cached
  model; there is currently no `ContainersChanged` subscriber in this client
  or menu refresh on model changes. Agent-side monitors alone therefore cannot
  satisfy live create/remove acceptance. Update the client model and all open
  menus when changes arrive, including safe handling of removals during spawn.
- Restore requires more than a stable name: verify how BlueShell saves and
  resolves the target before claiming restored NSL tabs work. Do not silently
  redirect a missing or unusable restored target to a different machine.
- Both discovery and spawn need host execution when the agent is sandboxed.
  A sandbox PATH lookup is not proof that the host CLI exists. Resolve and run
  on the host, preserve the intended per-user state environment, and verify
  `flatpak-spawn` permissions, PTY FDs and host-only installations in practice.

The existing agent files are GPL-3.0-or-later, while BlueShell's root license
is MIT. Igloo's inspected sources are GPL-3.0-or-later. This evaluation copies
no implementation; independently implement against NSL's documented CLI. Any
direct source reuse needs a component-level license review first.

## Verification still required

Run the complete provider module (`meson setup agent-build third_party/ptyxis-agent`
then `meson test -C agent-build vm-providers --print-errorlogs`) and add tests
for absent/disabled NSL, host lookup, schema errors, duplicate names, each
state, identity-preserving refresh, failure retention and out-of-order results.
Test the client/model notification and selected-target spawn arguments/PTY too.

On an NSL-capable host, with a **disposable** machine and the opt-in provider:

1. Record `nsl version`, `nsl doctor` and `nsl list --json`; check no CLI and
   disabled-provider cases leave other targets unchanged.
2. Create and start a machine, inspect the picker without restarting BlueShell,
   open its terminal and confirm the guest identity and PTY. Stop it and verify
   the stopped entry can be entered again. Remove it and confirm it disappears
   without duplicates or stale selectable entries. Do not remove real data.
3. Exercise incomplete and removing records in a controlled test fixture;
   confirm neither is selectable. Restore a saved NSL tab with both an existing
   and a missing machine, including after an agent restart.
4. Repeat native and actual Flatpak sandbox-to-host paths, including an NSL
   executable present only on the host and a non-default `NSL_HOME`. Check
   shared versus isolated working directories and environment forwarding.

These are outstanding acceptance tests, not results from this investigation.
