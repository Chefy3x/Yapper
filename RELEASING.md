# Releasing Yapper

Users install Yapper from the DMG attached to each [GitHub Release](https://github.com/Chefy3x/Yapper/releases)
(the site's download button always points at the latest one). Installed copies
update themselves via [Sparkle](https://sparkle-project.org), which reads
[`site/appcast.xml`](site/appcast.xml) from this repo's `main` branch.

## One-time setup

1. **Developer ID certificate** — in Xcode → Settings → Accounts → Manage
   Certificates, create a *Developer ID Application* certificate (requires a
   paid Apple Developer account). Distribution signing uses this; day-to-day
   dev signing config stays in the gitignored `project-local.yml`.
2. **Notarization credentials** — create an app-specific password at
   [account.apple.com](https://account.apple.com), then store it:

   ```sh
   xcrun notarytool store-credentials yapper-notary \
       --apple-id <your-apple-id> --team-id <your-team-id>
   ```

   The release script reads the profile name from `$NOTARY_PROFILE`
   (default `yapper-notary`). Nothing is stored in the repo.
3. **Sparkle EdDSA key** — already in the login Keychain (`generate_keys`
   created it; its public half is `SUPublicEDKey` in `project.yml`). If it is
   ever lost, shipped apps can no longer verify updates — back it up with
   `generate_keys -x <file>` somewhere safe (not the repo).
4. **Tools** — `xcodegen` and `gh` (authenticated) on `PATH`. The script
   downloads Sparkle's CLI tools on first run and caches them in
   `~/Library/Caches/YapperRelease`.

## Cutting a release

```sh
./scripts/release.sh 0.2.0
```

The script:

1. Bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`
   (and the version pill on the site), regenerates the Xcode project.
2. Archives Release, exports with Developer ID signing.
3. Notarizes and staples the app, wraps it in `build/release/Yapper.dmg`,
   then notarizes and staples the DMG too.
4. Signs the DMG with the Sparkle key and prepends an entry to
   `site/appcast.xml`.
5. Asks before publishing: commits the version bump + appcast, pushes, and
   creates the GitHub release with the DMG attached.

Review the staged diff before answering yes at step 5. Updates go live the
moment the appcast lands on `main`; running apps pick them up on their next
scheduled check, or immediately via the menu's *Check for Updates…*.

## If a release goes bad

Delete the GitHub release and tag, remove the `<item>` from
`site/appcast.xml`, and push. Apps that already updated stay on the pulled
version until the next release; ship a fixed version promptly.
