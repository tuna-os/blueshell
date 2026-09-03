# Observability Assessment & Stack Guidelines

## Operational Posture

`blueshell` is a modern terminal application for the GNOME desktop powered by GTK 4, Libadwaita, and VTE (`org.tunaos.blueshell`).

### Telemetry Exporter Configuration
- **Backend Status:** No external metric collection or log forwarding exporter is configured.
- **Client-Side Logging:** `blueshell` uses standard GLib/GTK structured logging primitives (`g_debug`, `g_warning`, `g_message`) and VTE stderr streams.
- **Local Diagnostics:** Terminal execution logs and subprocess PTY diagnostics are emitted to stdout/stderr or captured via journald (`journalctl --user -u org.tunaos.blueshell`).

## Stack Guidelines & Privacy Boundary

1. **Zero External Exporters:** Do not introduce external telemetry collectors, HTTP log forwarders, or analytics SDKs.
2. **Local Diagnostics Only:** All terminal session data, environment variables, and PTY diagnostics must remain strictly on the local system.
3. **Structured Stderr/Stdout:** Future logging improvements must target standard GLib log domains and local log sinks without network side-effects.
