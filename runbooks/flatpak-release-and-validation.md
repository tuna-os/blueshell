# Flatpak Release & Validation Runbook

## Overview
Operational guide for validating Flatpak terminal manifests, checking host PTY permissions, and performing release build verification.

## Pre-Release Validation

1. **Verify Manifest Permissions:**
   Ensure `org.tunaos.blueshell.json` (or ptyxis manifest) includes required permissions:
   - `--talk-name=org.freedesktop.Flatpak`
   - `--filesystem=host`
   - `--device=all`

2. **Build and Test Local Package:**
   ```bash
   flatpak-builder --force-clean build-dir org.tunaos.blueshell.json
   flatpak-builder --run build-dir org.tunaos.blueshell.json blueshell
   ```

3. **Verify Host Subshell Execution:**
   Confirm `flatpak run org.tunaos.blueshell` opens a responsive PTY subshell without permission errors.

4. **Sanity Check Palette & Configuration:**
   Test custom palettes, light/dark theme switching, and tab management.

## Release Process
Tag the release after sanity checks pass:
```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```
