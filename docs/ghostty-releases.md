# Ghostty release tarballs for FlatPark

FlatPark requires a fixed URL, SHA-256 and byte size for each extra-data download
([maintainer request](https://github.com/flatpark/flatpark/issues/928#issuecomment-6566438525)).
A `.flatpak` bundle or an OCI registry reference does not meet that contract.

The Ghostty workflow retains the shared OCI build and publication. Its export
job downloads the **same run's** `oci-x86_64` and `oci-aarch64` artifacts, imports
with Flatpak, checks the application/architecture ref and ELF machine, and
archives only the imported commit's `files/` directory (the built `/app` tree).
It does not rebuild Ghostty or read mutable registry tags. The importer discovers
the built branch instead of assuming the manifest's `tip` or the action's
`master` default.

Tarballs use sorted relative paths, fixed gzip/tar timestamps and ownership,
and retain executable modes. Absolute/escaping symlinks, special files, and
setuid/setgid files fail the export. Identical input trees produce identical
bytes; this does **not** assert that separate compiler/SDK runs are reproducible.
Each JSON receipt records the upstream pin, packaging commit, manifest digest,
OSTree commit/ref, architecture, SHA-256 and byte size.

## Publishing after review

After this workflow change merges, dispatch **Publish Ghostty Flatpak** on
`ptyxis-port` with `release-tarballs` enabled. Schedule runs and PR builds export
validation artifacts only. The release job runs only on an explicit dispatch
on the source repository's default branch, after both architecture exports pass.

Tags and asset names use `ghostty-<full packaging commit>-r<run ID>a<attempt>`.
This is a packaging revision, not an upstream semantic version. The namespace
cannot trigger Blueshell's `v*` tag workflow. Every run attempt has a distinct
identity; no release is overwritten. The job creates a draft release with both
architectures, downloads its assets, validates them against the original receipt,
and only then publishes it without changing the repository's latest release.
An upload/verification failure leaves a draft for inspection, not a public
partial release. Do not use clobber or repoint an existing tag to repair it.

## Preparing the FlatPark PR

Use the published release's actual asset URLs, download both, and independently
check `SHA256SUMS`, receipt byte sizes and archive contents. No placeholder pins
belong in a submission. Retain `com.mitchellh.ghostty`, the upstream pin and the
current sandbox permissions. This is Tuna-maintained packaging, not upstream
endorsement; support links go to tuna-os/blueshell.

The built launcher calls `/app/bin/ghostty.bin`. When installing the tree under
`/app/extra/ghostty`, expose that binary at `/app/bin/ghostty.bin`, preserve the
launcher, set the payload library/resource paths, and expose `/app/share/ghostty`
and `/app/share/terminfo` for host shell integration. Check all these against
the actual release tree. FlatPark's catalog currently uses GNOME 51 whereas
this producer uses GNOME 50: validate the package on the catalog runtime rather
than changing the producer runtime or upstream pin in this release work.

Follow FlatPark's testing playbook: descriptor/audit, download pins, root without
capabilities `apply_extra`, local signed-repository installation, drawing,
host shell, resource/terminfo paths, config persistence, home-folder diff,
window class and second launch. Do not open the packaging PR before running the
app; record separately what ran on x86_64 and aarch64.

## Local checks

```sh
python3 -m unittest discover -s .github/scripts/tests -p test_ghostty_release.py -v
actionlint .github/workflows/publish-ghostty-flatpak.yml
bash .github/scripts/tests/ghostty-oci-roundtrip.sh
```

The unit suite verifies archive determinism, extraction and permissions, unsafe
links/files, hardlinks, both-architecture receipts, corruption and mixed builds.
The round-trip check uses Flatpak/OSTree with tiny, non-runnable ELF fixtures
for both architectures. Real Ghostty build and runtime tests additionally need
the workflow artifacts and a graphical test session; fixtures do not substitute
for those checks.
