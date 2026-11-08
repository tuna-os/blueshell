#!/usr/bin/env bash
# Exercise Flatpak's real OCI export/import with tiny, non-runnable ELF fixtures.
set -euo pipefail
scripts=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIO_USE_VFS=local
for arch in x86_64 aarch64; do
    build="$work/$arch/build"
    mkdir -p "$build/files/bin" "$build/files/share/ghostty" "$build/export"
    cat > "$build/metadata" <<EOF
[Application]
name=com.mitchellh.ghostty
runtime=org.gnome.Platform/$arch/50
sdk=org.gnome.Sdk/$arch/50
command=ghostty
EOF
    printf '#!/bin/sh\nexit 0\n' > "$build/files/bin/ghostty"
    python3 - "$build/files/bin/ghostty.bin" "$arch" <<'PY'
import sys
from pathlib import Path
header = bytearray(64)
header[:6] = b'\x7fELF\x02\x01'
header[18:20] = (62 if sys.argv[2] == 'x86_64' else 183).to_bytes(2, 'little')
Path(sys.argv[1]).write_bytes(header)
PY
    chmod 755 "$build/files/bin/ghostty" "$build/files/bin/ghostty.bin"
    flatpak build-export --arch="$arch" "$work/$arch/repo" "$build" tip
    flatpak build-bundle --oci --arch="$arch" "$work/$arch/repo" "$work/$arch/oci" com.mitchellh.ghostty tip
    printf '        commit: %040d\n' 1 > "$work/manifest.yml"
    python3 "$scripts/export-ghostty-release.py" \
        --oci "$work/$arch/oci" --arch "$arch" \
        --source-commit 1111111111111111111111111111111111111111 \
        --run-id 123 --attempt 1 --manifest "$work/manifest.yml" --output "$work/release"
done
python3 "$scripts/prepare-ghostty-release.py" "$work/release"
(cd "$work/release" && sha256sum -c SHA256SUMS)
