# Promoting BlueShell to the tuna-os org + Flatpak remote

Goal: ship BlueShell (now at `tuna-os/blueshell` — **transfer done
2026-08-17**) through the TunaOS Flatpak remote (`https://tunaos.org/flatpak/`,
OCI images on `ghcr.io/tuna-os/*`, index maintained in `tuna-os/docs`
and served via Cloudflare Pages).

Repo-side groundwork in this tree is done:
`.github/workflows/publish-flatpak.yml` is committed and self-gates on
`github.repository == 'tuna-os/blueshell'`, so it activates on
transfer — nothing here blocks on the org. The remaining steps need
org permissions and are listed in order.

## 1. Transfer the repository — ✅ DONE (2026-08-17)

GitHub → repo **Settings → General → Danger Zone → Transfer ownership**
→ `tuna-os`. (Org owner must accept; hanthor needs create-repo rights
in the org or an owner initiates.) GitHub keeps redirects from the old
URL, so existing clones and the nightly.link install command keep
working during the switchover.

After transfer, in the new repo:

- Re-create the Actions secret(s): `FLATPAK_INDEX_TOKEN` — a PAT with
  write access to `tuna-os/docs` (used to register/update the app in
  the remote's index). Secrets do NOT transfer.
- Confirm Actions are enabled and `GITHUB_TOKEN` has `packages: write`
  (the publish workflow requests it, ghcr push needs it).
- Update the repo description/topics; keep the `upstream-sync` label
  (the weekly sync workflow creates issues with it).

## 2. Rename the app ID: `dev.hanthor.BlueShell` → `org.tunaos.BlueShell` — ✅ DONE

TunaOS convention is `org.tunaos.<App>`. One PR, mechanical:

| File | Change |
| --- | --- |
| `flatpak/org.tunaos.BlueShell.yml` | renamed file, `app-id:` field |
| `flatpak/org.tunaos.BlueShell.desktop` | renamed file; updated `Icon=` and `StartupWMClass=` |
| `flatpak/org.tunaos.BlueShell.svg` | renamed file (manifest install path follows app ID) |
| `.github/workflows/ghostty-ptyxis.yml` | `manifest-path`, bundle name |
| `.github/workflows/publish-flatpak.yml` | `APP_ID` env at the top |
| `README.md`, `HACKING.md` | install commands, App ID mention |

Notes:

- **Icon: done.** `flatpak/org.tunaos.BlueShell.svg` is original
  BlueShell artwork (blue scallop + terminal prompt), installed by the
  manifest under the app ID; `rename-icon` was dropped so Ghostty's
  unlicensed icon is no longer shipped. Rename the SVG alongside the
  app-id flip. `rename-appdata-file` still reuses upstream's metainfo —
  replace with a BlueShell metainfo file before Flathub-style listing
  polish matters.
- Keep `--own-name=com.mitchellh.ghostty` in `finish-args` for now: the
  GTK application still registers on D-Bus under upstream's id
  (invisible plumbing, not user-facing branding), and the
  single-instance guard silently exits without it. Longer-term, patch
  the app ID in the fork and add a `CONFLICT_HOTSPOTS.md` entry.
- Internal GObject class names (`GhosttyPtyxis*` in
  `src/apprt/gtk/class/` and their blueprint templates) are not
  user-facing and can be renamed to `BlueShell*` in a follow-up
  mechanical PR — not a blocker.
- Users of the old `dev.hanthor` install must
  `flatpak uninstall dev.hanthor.BlueShell` once; app IDs have no
  migration path.

## 3. Register in the TunaOS Flatpak remote

Per `tuna-os/flatpak-index` ("adding apps" flow):

1. Repo lives under `tuna-os/` — done by step 1.
2. Manifest at the expected path/name for the index tooling
   (`org.tunaos.BlueShell` — step 2). If the index tooling requires
   the manifest at repo root, add a thin root-level manifest that
   `base`s or mirrors `flatpak/org.tunaos.BlueShell.yml` rather
   than duplicating it.
3. CI workflow `publish-flatpak.yml` — already committed here, copied
   from `tuna-os/finupdate` (the canonical tuna-os pipeline): native
   x86_64 + aarch64 OCI builds in the GNOME 50 container → skopeo push
   to `ghcr.io/tuna-os/blueshell:latest-<arch>` → vendored
   `.github/scripts/update-index.py` updates
   `tuna-os/docs:static/flatpak/index/static` and pushes with
   `FLATPAK_INDEX_TOKEN`. Tags `v*` also attach .flatpak bundles to the
   GitHub release.
4. Set the secret (step 1) and push; Cloudflare Pages redeploys the
   index and the app appears in the remote.

Users then get it with:

```sh
flatpak remote-add --if-not-exists tuna-os https://tunaos.org/flatpak/tuna-os.flatpakrepo
flatpak install tuna-os org.tunaos.BlueShell
```

Status: ✅ live. `app/org.tunaos.BlueShell/{x86_64,aarch64}/master` is in
`tuna-os/docs:static/flatpak/index/static` and every push to `ptyxis-port`
refreshes it.

## 3b. Stock upstream Ghostty in the same remote

The remote also carries unmodified upstream Ghostty
(`com.mitchellh.ghostty`), published by
`.github/workflows/publish-ghostty-flatpak.yml`. That file is trigger
policy only — the body is the same reusable
`tuna-os/.github/.github/workflows/publish-flatpak.yml` every other
tuna-os app calls. Three things differ from BlueShell's own publish:

- It builds from a clean checkout of `ghostty-org/ghostty` (the reusable
  workflow's `source-repo` input) using **upstream's own** manifest,
  `dependencies.yml` and `zig-packages.json`. Nothing about the app is
  vendored here, so upstream dependency and runtime bumps need no action
  in this repo.
- It runs weekly (Sundays 05:00 UTC) plus `workflow_dispatch`, rather
  than on push. The reusable pipeline has no "upstream unchanged"
  short-circuit, so every run is two full Zig builds.
- It publishes to `ghcr.io/tuna-os/ghostty` and gets its own index
  entry, separate from blueshell's.

Two traps worth knowing, because both were nearly landmines:

- Upstream's manifest sets `default-branch: tip`, but the remote's
  `tuna-os.flatpakrepo` declares `DefaultBranch=master` — a `tip` ref
  would make `flatpak install tuna-os com.mitchellh.ghostty` fail with
  "Nothing matches" (the 2026-07-27 incident, which
  `check-flatpak-remote.py` exists to catch). No patch is needed:
  flatpak-builder resolves the branch as manifest `branch:` →
  `--default-branch` → manifest `default-branch:`, and
  `flatpak-github-actions` always passes `--default-branch=master`. The
  ref published is `master`. Keep that in mind before "simplifying" the
  build away from that action.
- The GHCR package must be made **public** by hand after the first
  successful run. A private package fails to install exactly like a
  missing one.

## 4. tunaos.org site listing + install instructions

Being installable is not the finish line — the app must be discoverable:

1. **tunaos.org listing** — the site is a Docusaurus build from
   `tuna-os/docs`, and an app is listed in more places than one page:

   - `src/data/projects.ts` — drives the `/projects` card, the `/<app>`
     landing page and `/install?app=<id>`.
   - `src/pages/<app>.tsx` — a thin wrapper over `ProjectLanding`.
   - `docs/<app>/index.md` — the reference page.
   - `sidebars.ts` — the entry under **Apps**.
   - `src/pages/flatpak.tsx` and `docs/flatpak/index.mdx` — both install
     catalogs.

   One trap: `tuna-os/docs` runs `scripts/sync-org-docs.mjs`, which
   overwrites `docs/<slug>/` from each org repo's README
   unconditionally — and `docs/blueshell/` is such a tree. Both slugs
   have to be in that script's `HAND_AUTHORED` set or the next sync
   reverts the page.

   `docs/site/blueshell/index.md` in this repo was the original draft for
   that page. The published copy lives in `tuna-os/docs` and has moved on
   from it; treat the local file as history rather than a source to
   re-copy.

   Still worth adding: a screenshot from the CI `ui-walkthrough` artifact
   (`02-prefs-appearance.png` shows the app best).

2. **README install instructions**: ✅ DONE — the "available once…"
   note is gone and the remote is the recommended path.

## 5. Post-promotion checklist

- [x] `ptyxis-tests` and `ghostty-ptyxis` (bundle) workflows green in the org repo
- [x] `publish-flatpak` run pushed an image to `ghcr.io/tuna-os/blueshell` and the index commit landed in `tuna-os/docs`
- [x] BlueShell present in the remote index as `app/org.tunaos.BlueShell/{x86_64,aarch64}/master`
- [x] README install section switched to the remote as the primary path (the rolling `tip` release is the "bleeding edge" alternative)
- [x] `upstream-sync.yml` failure fixed — the `upstream-sync` label does not survive a repo transfer, and every weekly run since 2026-08-17 failed at `gh issue create --label upstream-sync`. Label recreated 2026-09-06.
- [x] Ghostty: first `publish-ghostty-flatpak` run green (2026-09-06), index entry `app/com.mitchellh.ghostty/{x86_64,aarch64}/master` live. The GHCR package came out **public** on first push, so the manual visibility flip this document warned about was not needed — worth re-checking rather than assuming for the next app.
- [x] Install of both verified from the live remote: `flatpak install tuna-os com.mitchellh.ghostty` deploys `app/com.mitchellh.ghostty/x86_64/master` from origin `tuna-os` and runs (Ghostty 1.3.2-main).
- [x] tunaos.org site PR merged — tuna-os/docs#373, both apps listed in all six places.
- [x] Both apps added to `tuna-os/docs:static/flatpak/expected-apps.json` — tuna-os/docs#374. `check-flatpak-remote.py` goes from a standing "2 app(s) not in expected-apps.json" warning to a real check.
- [x] `hanthor/blueshell` archived, its PR closed. The fork had drifted 5 ahead / 25 behind; its work is in tuna-os/blueshell#83 and #84.
- [ ] `upstream-sync.yml` confirmed working under the org on a real Monday run (label fixed, guards in #84 — but not yet exercised by a scheduled run)
- [ ] `publish-ghostty-flatpak` confirmed on its first *scheduled* run (Sundays 05:00 UTC; so far only dispatched by hand)
- [ ] Old repo redirect verified; announce the move in tunaOS channels

## 6. Known rough edges

- **`Test` never completes in this repo.** Upstream's `test.yml` runs on
  `namespace-profile-ghostty-*` runners, which are Namespace.so machines
  the tuna-os org does not have. Every job on those labels queues
  forever, so "Required Checks: Test" is permanently pending on every
  PR and cannot be a merge gate here. `ptyxis-tests` is the suite that
  actually runs. Either wire up equivalent runners or re-point those
  jobs at GitHub-hosted labels.
- **`publish-flatpak.yml` is still a vendored copy** of the org
  pipeline, including its own `update-index.py`, and is not covered by
  `tuna-os/.github`'s drift check. Tracked in
  tuna-os/blueshell#85; not urgent, because it carries a `release-tip`
  job the reusable workflow has no equivalent for.
- **`ghcr.io/tuna-os/blueshell` has no plain `:latest` tag** — the
  vendored workflow pushes only `latest-<arch>`. Harmless (flatpak
  resolves through the index), but it makes a plain `docker pull` of
  that path 404 while `ghcr.io/tuna-os/ghostty:latest` works.
