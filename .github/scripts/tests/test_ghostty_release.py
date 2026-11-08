import hashlib
import json
import importlib.util
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('exporter', Path(__file__).parents[1] / 'export-ghostty-release.py')
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'app'
        (self.root / 'bin').mkdir(parents=True)
        (self.root / 'bin/ghostty').write_bytes(b'payload')
        (self.root / 'bin/ghostty').chmod(0o755)
        (self.root / 'ghostty').symlink_to('bin/ghostty')

    def test_reproducible_and_extractable(self):
        one = Path(self.temp.name) / 'one.tar.gz'
        two = Path(self.temp.name) / 'two.tar.gz'
        exporter.archive_tree(self.root, one)
        os.utime(self.root / 'bin/ghostty', (12345, 12345))
        exporter.archive_tree(self.root, two)
        self.assertEqual(hashlib.sha256(one.read_bytes()).digest(), hashlib.sha256(two.read_bytes()).digest())
        with tarfile.open(one) as tar:
            self.assertEqual(tar.getnames(), ['bin', 'bin/ghostty', 'ghostty'])
            for member in tar:
                self.assertEqual((member.uid, member.gid, member.mtime), (0, 0, 0))
            dest = Path(self.temp.name) / 'extract'
            tar.extractall(dest, filter='data')
        self.assertEqual((dest / 'ghostty').read_bytes(), b'payload')
        self.assertTrue(os.access(dest / 'bin/ghostty', os.X_OK))
        with self.assertRaises(FileExistsError):
            exporter.archive_tree(self.root, one)

    def test_reject_escape(self):
        for target in ('/etc/passwd', '../outside', 'bin/../../outside'):
            with self.subTest(target=target):
                link = self.root / 'escape'
                link.symlink_to(target)
                with self.assertRaisesRegex(ValueError, 'escaping symlink'):
                    exporter.archive_tree(self.root, Path(self.temp.name) / 'bad.tar.gz')
                link.unlink()

    def test_reject_special_files_and_privileged_mode(self):
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, 'unsupported file type'):
            exporter.archive_tree(self.root, Path(self.temp.name) / 'bad.tar.gz')
        fifo.unlink()
        (self.root / 'bin/ghostty').chmod(0o4755)
        with self.assertRaisesRegex(ValueError, 'privileged mode'):
            exporter.archive_tree(self.root, Path(self.temp.name) / 'bad.tar.gz')

    def test_hardlinks_and_unicode_paths(self):
        os.link(self.root / 'bin/ghostty', self.root / 'hardlink')
        (self.root / 'é').write_text('unicode')
        archive = Path(self.temp.name) / 'links.tar.gz'
        exporter.archive_tree(self.root, archive)
        with tarfile.open(archive) as tar:
            self.assertTrue(tar.getmember('hardlink').isfile())
            self.assertEqual(tar.extractfile('hardlink').read(), b'payload')
            self.assertEqual(tar.extractfile('é').read(), b'unicode')


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('prepare', Path(__file__).parents[1] / 'prepare-ghostty-release.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tag = 'ghostty-' + 'a' * 40 + '-r123a1'
        for arch in ('x86_64', 'aarch64'):
            name = f'{self.tag}-{arch}.tar.gz'
            (self.root / name).write_bytes(arch.encode())
            receipt = dict(tag=self.tag, filename=name, app_id=exporter.APP_ID, arch=arch,
                           sha256=hashlib.sha256(arch.encode()).hexdigest(), size=len(arch),
                           source_commit='a' * 40, upstream_commit='b' * 40, manifest_sha256='c' * 64)
            (self.root / f'{name}.json').write_text(json.dumps(receipt))

    def test_both_arches_and_checksums(self):
        self.assertEqual(self.module.prepare(self.root), self.tag)
        self.assertEqual(len((self.root / 'SHA256SUMS').read_text().splitlines()), 2)
        self.assertIn('not an upstream', (self.root / 'release-notes.md').read_text())

    def test_missing_arch_fails(self):
        next(self.root.glob('*aarch64*.json')).unlink()
        with self.assertRaisesRegex(ValueError, 'expected one receipt'):
            self.module.prepare(self.root)

    def test_corrupt_bytes_fail(self):
        next(self.root.glob('*x86_64.tar.gz')).write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum or size mismatch'):
            self.module.prepare(self.root)

    def test_mixed_builds_fail(self):
        path = next(self.root.glob('*aarch64*.json'))
        receipt = json.loads(path.read_text())
        receipt['upstream_commit'] = 'd' * 40
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'provenance mismatch'):
            self.module.prepare(self.root)

    def test_wrong_identity_fails(self):
        path = next(self.root.glob('*aarch64*.json'))
        receipt = json.loads(path.read_text())
        receipt['filename'] = '../outside'
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.module.prepare(self.root)


if __name__ == '__main__':
    unittest.main()
