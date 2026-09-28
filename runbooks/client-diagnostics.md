# Client & Terminal Diagnostic Runbook

## Overview
Standardized diagnostic procedure for troubleshooting terminal session crashes, PTY allocation failures, VTE render errors, and Flatpak container spawning issues in `blueshell`.

## Diagnostic Steps

1. **Capture Structured GLib Debug Logs:**
   Launch `blueshell` from terminal with GLib debug logging enabled:
   ```bash
   G_MESSAGES_DEBUG=all blueshell
   ```
   Or for Flatpak execution:
   ```bash
   flatpak run --env=G_MESSAGES_DEBUG=all org.tunaos.blueshell
   ```

2. **Inspect Subprocess PTY Spawning:**
   Verify PTY allocation and subshell environment variables:
   ```bash
   G_MESSAGES_DEBUG=Ptyxis blueshell --standalone
   ```

3. **Check Container & Host IPC Sockets:**
   Verify flatpak host portal access when spawning subshells inside container sandboxes:
   ```bash
   flatpak-spawn --host echo "Host IPC connection functional"
   ```

4. **Font & VTE Rendering Issues:**
   If character rendering or font metrics fail in VTE:
   ```bash
   VTE_DEBUG=all blueshell
   ```

## Escalation
If issues persist due to VTE panics or container portal failures, gather diagnostic logs and open an issue using `.github/ISSUE_TEMPLATE/incident_report.md`.
