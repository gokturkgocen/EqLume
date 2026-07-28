# Eqlume Mac App Store Release

This document tracks the App Store-specific distribution path. The open-source build and its existing installation flow remain unchanged.

## Technical status

- [x] App Sandbox entitlements are separated from development entitlements.
- [x] The Core Audio process tap and private aggregate device pass a sandboxed runtime probe.
- [x] Outgoing network access is declared; the Spotify OAuth callback server is compiled out of the App Store flavor.
- [x] Apple Events targets are explicitly listed for review.
- [x] The development-only `get-task-allow` entitlement is absent from the App Store build.
- [x] The CC BY-NC-SA Discogs-EffNet model and derived label data are excluded from the App Store bundle.
- [x] Missing local classification falls back safely to the Pop preset after catalog lookup.
- [x] Privacy policy and third-party notices are reachable from the app.
- [x] App category, copyright, and export-compliance metadata are declared.
- [ ] Apple Events behavior must be exercised with Spotify, Music, Chrome, and Safari under sandbox.
- [x] Spotify OAuth, Web API pre-fetch, and Keychain token storage are absent from the App Store flavor.
- [x] A Mac App Distribution provisioning profile for `com.gokturkgocen.Eqlume` has been created.
- [x] Build 4 is signed with Apple Distribution and uploaded to App Store Connect.

Run the automated local checks with:

```bash
./scripts/preflight-appstore.sh
```

Run the isolated Core Audio sandbox test with:

```bash
./build.sh sandbox-probe
./build/Eqlume-SandboxProbe.app/Contents/MacOS/Eqlume-SandboxProbe
```

Expected terminal result:

```text
EQLUME_SANDBOX_PROBE=PASS detail=none
```

After downloading the provisioning profile and installing Apple's distribution
certificates, create the upload package with:

```bash
PROVISIONING_PROFILE="/path/to/Eqlume.provisionprofile" ./scripts/package-appstore.sh
```

The script deliberately stops before changing or uploading anything in App Store Connect.

## App Store Connect record

- Bundle ID: `com.gokturkgocen.Eqlume`
- Platform: macOS
- Primary category: Utilities
- Version: `1.0`
- SKU suggestion: `EQLUME-MAC-001`
- Privacy policy: `https://github.com/gokturkgocen/SesEQ/blob/main/PRIVACY.md`
- Support URL: `https://github.com/gokturkgocen/SesEQ/issues`
- Marketing URL: `https://github.com/gokturkgocen/SesEQ`

Create the App ID and Mac App Distribution profile in the Apple Developer portal before producing the final package. No suitable macOS provisioning profile was installed during the July 21, 2026 preflight.

## Review notes draft

Eqlume is a menu-bar-only system equalizer. Click the waveform icon in the menu bar to open the interface. The app uses Apple's public Core Audio process tap API to process system audio in memory. Audio is neither saved nor uploaded. For safety, equalization engages only when the built-in 3.5 mm headphone output is active and bypasses other outputs.

Automatic preset selection optionally reads now-playing metadata from supported media apps. Network catalog lookups send artist and track text to MusicBrainz or Apple's iTunes Search API. Spotify now-playing and transport integration uses AppleScript; the OAuth/Web API queue pre-fetch feature is not included in the App Store flavor. The App Store build does not include the third-party Discogs-EffNet classifier.

The temporary Apple Events exceptions enable now-playing and transport integration with these explicit targets: Apple Music, Spotify, Chrome, and Safari. All integrations are user initiated and remain optional.

## Product page checklist

- [x] Final app icon at all required macOS sizes.
- [x] Three 2880 × 1800 Mac screenshots without copyrighted album artwork.
- [x] English and Turkish name, subtitle, description, and keywords.
- [ ] Privacy questionnaire matching `PRIVACY.md`.
- [ ] Age rating questionnaire.
- [ ] Support and privacy URLs publicly accessible.
- [ ] Review contact information and reviewer instructions.
- [ ] TestFlight internal test on a clean Apple silicon Mac.
- [ ] Test sleep/wake, jack unplug/replug, app quit, and permission denial paths.

Generate the final screenshots with:

```bash
./build.sh screenshots
./build/Eqlume-Screenshots.app/Contents/MacOS/Eqlume-Screenshots
```

The PNG files are written to `assets/app-store/`.
