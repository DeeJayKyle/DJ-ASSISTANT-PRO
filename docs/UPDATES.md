# Auto-update

DJ Assistant uses the Tauri updater. On start-up (and from **Settings → Updates**) it asks GitHub for `latest.json`, and if a newer version exists it downloads the installer, **verifies its signature** with the public key built into the app, installs it in place (passive mode) and restarts. Your catalogue, crates and settings are kept. Only the app version and platform are sent; checks can be switched off in Settings.

## Where the app looks

v1.0.0 checks, in order:

1. `https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO/releases/latest/download/latest.json`
2. `https://github.com/DeeJayKyle/dj-assistant-releases/releases/latest/download/latest.json`

The updater downloads anonymously, so **the release files must be publicly downloadable**. While DJ-ASSISTANT-PRO is private, update checks find nothing (the app keeps working normally). Choose one:

- **A. Make DJ-ASSISTANT-PRO public** — no other change needed; the next release is picked up automatically.
- **B. Keep the source private (chosen)** — a public repository `DeeJayKyle/dj-assistant-releases` holds only the installers, checksums, signatures and `latest.json`. The Release workflow publishes there automatically when the `RELEASES_TOKEN` secret is set (see below), and `latest.json` then points at that repository's downloads.

### Setting up option B (once)

1. On GitHub, create a **public** repository named `dj-assistant-releases` under `DeeJayKyle`, ticking "Add a README" (a release needs at least one commit to attach its tag to). No code goes in it.
2. Create a fine-grained personal access token (GitHub → Settings → Developer settings → Fine-grained tokens): repository access **only** `dj-assistant-releases`, permission **Contents: Read and write**, with an expiry date you will remember to renew.
3. In DJ-ASSISTANT-PRO, add it as the repository secret `RELEASES_TOKEN`, next to the two signing secrets below.
4. Run the Release workflow again for the current tag (e.g. `v1.2.0`). It rebuilds, signs, replaces the private release's files with a matching set and publishes the public copy with `latest.json`. Installed copies then see the update.

## One-time setup for automatic signing

The update signing key pair was generated for v1.0.0. The **public** key is in `src-tauri/tauri.conf.json`. The **private** key was handed to the owner separately and is not in this repository. Add it as repository secrets (Settings → Secrets and variables → Actions):

- `TAURI_SIGNING_PRIVATE_KEY` — contents of `dj-assistant-updater.key`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` — its password

With those set, the **Release** workflow signs the installer and publishes `latest.json` automatically. Keep a private backup of the key: if it is lost, installed copies can no longer verify updates and would need one manual reinstall.

## Releasing a new version

1. Bump the version in `Cargo.toml` (workspace), `package.json` and `src-tauri/tauri.conf.json`; update `docs/RELEASE_NOTES.md`.
2. Run the **Release** workflow with the new tag (e.g. `v1.0.1`).

## Signing outside CI

If the signing secrets are not set, the Release workflow still publishes the installer. Sign it locally with `npx tauri signer sign -f <key> -p <password> DJ-Assistant_x.y.z_x64-setup.exe`, build `latest.json` (version, notes, pub_date, and `platforms.windows-x86_64` with the signature and the release download URL), and run the **Attach updater manifest** workflow with the base64-encoded `latest.json`. This is how v1.0.0's `latest.json` was published.
