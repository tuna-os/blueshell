# Security Policy

## Overview

BlueShell is a GTK terminal emulator based on Ghostty's core terminal rendering engine, incorporating the ptyxis-agent backend for container and environment integration.

Because BlueShell builds on upstream Ghostty and integrates container runtime tools, vulnerabilities can exist at different layers of the software stack:

1. **BlueShell Fork Code:** GTK UI components (`src/apprt/gtk`), ptyxis-agent vendoring and integration (`vendor/ptyxis-agent`), Flatpak packaging and manifests, and CI/CD automation workflows (`.github/workflows`).
2. **Upstream Ghostty Core:** Terminal emulation, VT parser, renderer, configuration loader, and shared Zig core (`src/`).
3. **Container & System Integration:** Toolbox, Distrobox, Podman, and Flatpak sandbox runtimes.

Please follow the appropriate reporting procedure below based on the nature of the issue.

## Reporting a Vulnerability

### BlueShell-Specific Vulnerabilities

If you discover a vulnerability specific to BlueShell (e.g., GTK frontend flaws, ptyxis-agent integration issues, Flatpak manifest vulnerabilities, or workflow permissions):

1. **Do not** disclose security vulnerabilities via public GitHub issues, pull requests, or discussions.
2. Use **GitHub Private Vulnerability Reporting**:
   - Navigate to the repository's [Security Advisories](https://github.com/tuna-os/blueshell/security/advisories) tab.
   - Click **"Report a vulnerability"** to submit private details directly to project maintainers.
3. If GitHub Private Vulnerability Reporting is unavailable, open a private security advisory in [`tuna-os/tunaOS`](https://github.com/tuna-os/tunaOS/security/advisories), as described in the [TunaOS organization security policy](https://github.com/tuna-os/.github/blob/main/SECURITY.md). Include:
   - Description of the vulnerability and its potential impact
   - Affected versions or commit SHAs
   - Step-by-step reproduction instructions or proof-of-concept (PoC)
   - Any suggested mitigations or patches

### Upstream Ghostty Core Vulnerabilities

If you identify a vulnerability in upstream Ghostty core components (VT parsing, general terminal escape sequence processing, or core terminal engine):

- Follow the upstream [Ghostty Security Policy](https://github.com/ghostty-org/ghostty/security/policy).
- Report upstream vulnerabilities through upstream Ghostty's security advisory channels so that all downstream consumers can receive coordinated fixes.
- If an upstream vulnerability is under active exploitation or specifically impacts BlueShell builds, you may also notify BlueShell maintainers through private advisory after reporting upstream.

### Container & Third-Party System Integration

- BlueShell delegates container execution to host tools such as Toolbox, Distrobox, and Podman.
- Security boundaries and privilege separation within containers adhere to the respective security models of those host tools and the container engine.
- Container escape vulnerabilities or host container daemon issues should be reported to the respective upstream maintainers (e.g., Podman, Distrobox).

## Response & Patch Timelines

When a private security report is received for BlueShell:

- **Initial Acknowledgment:** Maintainers aim to acknowledge receipt of private vulnerability reports within **5 business days**, per the [TunaOS organization security policy](https://github.com/tuna-os/.github/blob/main/SECURITY.md).
- **Assessment & Triage:** Maintainers will evaluate severity, reproducibility, and scope, and keep the reporter updated through the private advisory.
- **Fix & Disclosure:** Security fixes will be developed in private security advisory forks and tested before release. Coordinated disclosure dates will be established with the reporter.

## Supported Versions

Security patches are actively applied to the default development branch (`ptyxis-port`) and included in the latest releases or tip builds.

| Version / Branch                        | Supported          |
| --------------------------------------- | ------------------ |
| `ptyxis-port` (main development branch) | :white_check_mark: |
| Latest stable tag / release             | :white_check_mark: |
| Older release tags                      | :x:                |

Users and downstream packagers are encouraged to keep their installations updated to the latest available release.
