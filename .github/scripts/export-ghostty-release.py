#!/usr/bin/env python3
"""Export the /app tree from the OCI artifact produced by this workflow."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile
import tempfile

APP_ID = 'com.mitchellh.ghostty'


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def archive_tree(root, destination):
    """Stable bytes for an identical tree; no host ownership or timestamps."""
    root = root.resolve()
    paths = sorted(root.rglob('*'))
    for path in paths:
        mode = path.lstat().st_mode
        if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
            raise ValueError(f'unsupported file type: {path}')
        if mode & (stat.S_ISUID | stat.S_ISGID):
            raise ValueError(f'privileged mode: {path}')
        if path.is_symlink():
            if os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(root):
                raise ValueError(f'escaping symlink: {path}')
    with destination.open('xb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as tar:
                for path in paths:
                    info = tar.gettarinfo(str(path), arcname=path.relative_to(root).as_posix())
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ''
                    # Archive hardlinks as regular files: self-contained paths only.
                    if info.islnk():
                        info.type = tarfile.REGTYPE
                        info.linkname = ''
                        info.size = path.stat().st_size
                    if info.isfile():
                        with path.open('rb') as source:
                            tar.addfile(info, source)
                    else:
                        tar.addfile(info)


def export(oci, arch, source_commit, run_id, attempt, manifest, output):
    if arch not in ('x86_64', 'aarch64'):
        raise ValueError('unsupported architecture')
    if not re.fullmatch('[0-9a-f]{40}', source_commit):
        raise ValueError('expected full packaging commit')
    if not re.fullmatch('[1-9][0-9]*', run_id) or not re.fullmatch('[1-9][0-9]*', attempt):
        raise ValueError('expected numeric run ID and attempt')
    pins = re.findall(r'^\s+commit: ([0-9a-f]{40})$', manifest.read_text(), re.M)
    if len(pins) != 1:
        raise ValueError('expected one upstream commit pin')
    tag = f'ghostty-{source_commit}-r{run_id}a{attempt}'
    name = f'{tag}-{arch}.tar.gz'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        repo = str(Path(temp) / 'repo')
        tree = Path(temp) / 'tree'
        run('ostree', f'--repo={repo}', 'init', '--mode=archive')
        run('flatpak', 'build-import-bundle', '--oci', repo, str(oci.resolve()))
        refs = run('ostree', f'--repo={repo}', 'refs').splitlines()
        if len(refs) != 1 or not refs[0].startswith(f'app/{APP_ID}/{arch}/'):
            raise ValueError(f'unexpected OCI refs: {refs}')
        commit = run('ostree', f'--repo={repo}', 'rev-parse', refs[0])
        run('ostree', f'--repo={repo}', 'checkout', '--user-mode', commit, str(tree))
        app = tree / 'files'
        for binary in ('ghostty', 'ghostty.bin'):
            if not (app / 'bin' / binary).is_file() or not os.access(app / 'bin' / binary, os.X_OK):
                raise ValueError(f'missing executable: {binary}')
        # Check ELF machine without executing either architecture's binary.
        header = (app / 'bin/ghostty.bin').read_bytes()[:20]
        machine = 62 if arch == 'x86_64' else 183
        if header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != machine:
            raise ValueError('binary architecture does not match OCI ref')
        if not (app / 'share/ghostty').is_dir():
            raise ValueError('missing Ghostty resources')
        archive_tree(app, output / name)
    asset = output / name
    receipt = dict(app_id=APP_ID, arch=arch, tag=tag, filename=name,
                   sha256=hashlib.sha256(asset.read_bytes()).hexdigest(), size=asset.stat().st_size,
                   source_commit=source_commit, upstream_commit=pins[0], ostree_commit=commit,
                   flatpak_ref=refs[0], manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest())
    (output / f'{name}.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('oci', 'arch', 'source-commit', 'run-id', 'attempt', 'manifest', 'output'):
        parser.add_argument(f'--{option}', required=True)
    args = vars(parser.parse_args())
    for option in ('oci', 'manifest', 'output'):
        args[option] = Path(args[option])
    print(json.dumps(export(**args), indent=2))
