# Promoting GhosttyPtyxis to the tuna-os org + Flatpak remote

Goal: move `hanthor/ghostty-ptyxis` → `tuna-os/ghostty-ptyxis` and ship
it through the TunaOS Flatpak remote (`https://tunaos.org/flatpak/`,
OCI images on `ghcr.io/tuna-os/*`, index maintained in `tuna-os/docs`
and served via Cloudflare Pages).

Repo-side groundwork in this tree is done:
`.github/workflows/publish-flatpak.yml` is committed and self-gates on
`github.repository == 'tuna-os/ghostty-ptyxis'`, so it activates on
transfer — nothing here blocks on the org. The remaining steps need
org permissions and are listed in order.

## 1. Transfer the repository

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

## 2. Rename the app ID: `dev.hanthor.GhosttyPtyxis` → `org.tunaos.GhosttyPtyxis`

TunaOS convention is `org.tunaos.<App>`. One PR, mechanical:

| File | Change |
| --- | --- |
| `flatpak/dev.hanthor.GhosttyPtyxis.yml` | rename file, `app-id:` field |
| `flatpak/dev.hanthor.GhosttyPtyxis.desktop` | rename file; `Icon=` stays `org.tunaos.GhosttyPtyxis` after rename-icon |
| `.github/workflows/ghostty-ptyxis.yml` | `manifest-path`, bundle name |
| `.github/workflows/publish-flatpak.yml` | `APP_ID` env at the top |
| `README.md`, `HACKING.md` | install commands, App ID mention |

Notes:

- Keep `rename-icon: com.mitchellh.ghostty` and
  `rename-appdata-file` — they rename *upstream Ghostty's* assets to
  whatever the manifest `app-id` is; no change needed beyond the id.
- Keep `--own-name=com.mitchellh.ghostty` in `finish-args`: the GTK
  application still registers on D-Bus under upstream's id, and the
  single-instance guard silently exits without it.
- Users of the old `dev.hanthor` install must
  `flatpak uninstall dev.hanthor.GhosttyPtyxis` once; app IDs have no
  migration path.

## 3. Register in the TunaOS Flatpak remote

Per `tuna-os/flatpak-index` ("adding apps" flow):

1. Repo lives under `tuna-os/` — done by step 1.
2. Manifest at the expected path/name for the index tooling
   (`org.tunaos.GhosttyPtyxis` — step 2). If the index tooling requires
   the manifest at repo root, add a thin root-level manifest that
   `base`s or mirrors `flatpak/org.tunaos.GhosttyPtyxis.yml` rather
   than duplicating it.
3. CI workflow `publish-flatpak.yml` — already committed here. On push
   to `ptyxis-port` it: builds the flatpak in the GNOME 50 container →
   exports an OCI image → pushes `ghcr.io/tuna-os/ghostty-ptyxis` →
   calls the index-update hook in `tuna-os/docs` with
   `FLATPAK_INDEX_TOKEN`.
4. Set the secret (step 1) and push; Cloudflare Pages redeploys the
   index and the app appears in the remote.

Users then get it with:

```sh
flatpak remote-add --if-not-exists tuna-os https://tunaos.org/flatpak/tuna-os.flatpakrepo
flatpak install tuna-os org.tunaos.GhosttyPtyxis
```

## 4. tunaos.org site listing + install instructions

Being installable is not the finish line — the app must be discoverable:

1. **tunaos.org listing**: the site is served from `tuna-os/docs`
   (Cloudflare Pages). Open a PR there adding GhosttyPtyxis to the apps
   section, alongside the flatpak-index entry. Ready-to-paste blurb:

   > **GhosttyPtyxis** — container-native terminal for GNOME. Ptyxis's
   > container-first UX (Toolbox / Distrobox / Podman tabs, profiles,
   > preferences) powered by the Ghostty rendering engine (GPU
   > acceleration, Kitty graphics, ligatures, splits).
   >
   > `flatpak install tuna-os org.tunaos.GhosttyPtyxis`

   Include a screenshot from the CI `ui-walkthrough` artifact
   (`02-prefs-appearance.png` shows the app best) and a link back to
   `tuna-os/ghostty-ptyxis`.

2. **README install instructions**: the README's "TunaOS Flatpak
   remote" section is already written (currently marked as pending
   promotion) — remove the "available once…" note and promote it to
   the recommended install path in the same PR that flips the app ID.

## 5. Post-promotion checklist

- [ ] `ptyxis-tests` and `ghostty-ptyxis` (bundle) workflows green in the org repo
- [ ] `publish-flatpak` run pushed an image to `ghcr.io/tuna-os/ghostty-ptyxis` and the index PR/commit landed in `tuna-os/docs`
- [ ] Fresh-machine install from the remote verified (`flatpak install tuna-os org.tunaos.GhosttyPtyxis`)
- [ ] README install section switched to the remote as the primary path (nightly.link bundle stays as the "bleeding edge" alternative)
- [ ] tunaos.org apps page lists GhosttyPtyxis with install command + screenshot (PR to `tuna-os/docs`)
- [ ] `upstream-sync.yml` weekly run confirmed working under the org (issue/PR creation permissions)
- [ ] Old repo redirect verified; announce the move in tunaOS channels
