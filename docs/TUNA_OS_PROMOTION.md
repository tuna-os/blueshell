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

## 2. Rename the app ID: `dev.hanthor.BlueShell` → `org.tunaos.BlueShell`

TunaOS convention is `org.tunaos.<App>`. One PR, mechanical:

| File | Change |
| --- | --- |
| `flatpak/dev.hanthor.BlueShell.yml` | rename file, `app-id:` field |
| `flatpak/dev.hanthor.BlueShell.desktop` | rename file; update `Icon=` and `StartupWMClass=` |
| `flatpak/dev.hanthor.BlueShell.svg` | rename file (manifest install path follows app ID) |
| `.github/workflows/ghostty-ptyxis.yml` | `manifest-path`, bundle name |
| `.github/workflows/publish-flatpak.yml` | `APP_ID` env at the top |
| `README.md`, `HACKING.md` | install commands, App ID mention |

Notes:

- **Icon: done.** `flatpak/dev.hanthor.BlueShell.svg` is original
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

## 4. tunaos.org site listing + install instructions

Being installable is not the finish line — the app must be discoverable:

1. **tunaos.org listing**: the site is a Docusaurus build from
   `tuna-os/docs` with one `docs/<app>/index.md` page per app. A
   ready-to-copy BlueShell page in the finupdate page's format lives at
   [`docs/site/blueshell/index.md`](site/blueshell/index.md) in this
   repo — PR it to `tuna-os/docs:docs/blueshell/index.md` (add a
   `sidebars.ts` entry if pages aren't auto-discovered). Short blurb if
   an apps-overview list also needs a row:

   > **BlueShell** — container-native terminal for GNOME. Ptyxis's
   > container-first UX (Toolbox / Distrobox / Podman tabs, profiles,
   > preferences) powered by the Ghostty rendering engine (GPU
   > acceleration, Kitty graphics, ligatures, splits).
   >
   > `flatpak install tuna-os org.tunaos.BlueShell`

   Include a screenshot from the CI `ui-walkthrough` artifact
   (`02-prefs-appearance.png` shows the app best) and a link back to
   `tuna-os/blueshell`.

2. **README install instructions**: the README's "TunaOS Flatpak
   remote" section is already written (currently marked as pending
   promotion) — remove the "available once…" note and promote it to
   the recommended install path in the same PR that flips the app ID.

## 5. Post-promotion checklist

- [ ] `ptyxis-tests` and `ghostty-ptyxis` (bundle) workflows green in the org repo
- [ ] `publish-flatpak` run pushed an image to `ghcr.io/tuna-os/blueshell` and the index PR/commit landed in `tuna-os/docs`
- [ ] Fresh-machine install from the remote verified (`flatpak install tuna-os org.tunaos.BlueShell`)
- [ ] README install section switched to the remote as the primary path (nightly.link bundle stays as the "bleeding edge" alternative)
- [ ] tunaos.org apps page lists BlueShell with install command + screenshot (PR to `tuna-os/docs`)
- [ ] `upstream-sync.yml` weekly run confirmed working under the org (issue/PR creation permissions)
- [ ] Old repo redirect verified; announce the move in tunaOS channels
