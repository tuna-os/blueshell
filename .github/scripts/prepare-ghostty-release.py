#!/usr/bin/env python3
"""Validate both release artifacts and prepare checksums and release notes."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def prepare(directory):
    receipts = []
    for arch in ('x86_64', 'aarch64'):
        matches = list(directory.glob(f'*-{arch}.tar.gz.json'))
        if len(matches) != 1:
            raise ValueError(f'expected one receipt for {arch}')
        receipt = json.loads(matches[0].read_text())
        tag = receipt['tag']
        if not re.fullmatch(r'ghostty-[0-9a-f]{40}-r[1-9][0-9]*a[1-9][0-9]*', tag):
            raise ValueError('invalid release tag')
        name = f'{tag}-{arch}.tar.gz'
        if receipt['filename'] != name or receipt['arch'] != arch or receipt['app_id'] != 'com.mitchellh.ghostty':
            raise ValueError('receipt identity mismatch')
        asset = directory / name
        if asset.stat().st_size != receipt['size'] or hashlib.sha256(asset.read_bytes()).hexdigest() != receipt['sha256']:
            raise ValueError('asset checksum or size mismatch')
        receipts.append(receipt)
    for field in ('tag', 'source_commit', 'upstream_commit', 'manifest_sha256'):
        if receipts[0][field] != receipts[1][field]:
            raise ValueError(f'architecture provenance mismatch: {field}')
    (directory / 'SHA256SUMS').write_text(''.join(f"{r['sha256']}  {r['filename']}\n" for r in receipts))
    (directory / 'release.json').write_text(json.dumps(receipts, indent=2) + '\n')
    notes = ['Tuna-maintained packaging of stock Ghostty; not an upstream Ghostty release or endorsement.',
             '', f"Upstream commit: `{receipts[0]['upstream_commit']}`.",
             f"Packaging commit: `{receipts[0]['source_commit']}`.",
             'Runtime: org.gnome.Platform 50. Application ID: com.mitchellh.ghostty.',
             'Each tarball contains the built /app tree from this run’s OCI artifact.',
             'Report packaging problems to https://github.com/tuna-os/blueshell/issues.', '',
             '| Architecture | Asset | SHA-256 | Bytes |', '| --- | --- | --- | ---: |']
    for r in receipts:
        notes.append(f"| {r['arch']} | {r['filename']} | `{r['sha256']}` | {r['size']} |")
    (directory / 'release-notes.md').write_text('\n'.join(notes) + '\n')
    return receipts[0]['tag']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    print(prepare(parser.parse_args().directory))
