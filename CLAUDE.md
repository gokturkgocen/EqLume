# EqLume

System-wide macOS equalizer, tuned for the **Moondrop Chu II IEM on the MacBook Air M4 3.5 mm
jack**. Captures system audio with a Core Audio process tap, runs it through `AVAudioUnitEQ`, and
picks a preset from whatever is playing. Menu-bar only. Author: Göktürk Göcen. MIT, except the
bundled ML model (CC BY-NC-SA 4.0 — see THIRD-PARTY.md).

This file holds what you need **before** opening a source file: invariants, traps that are not
visible from the code, decisions that live nowhere else, and honest state. The reasoning behind
each mechanism is in that file's own doc comments, which is where it belongs — `AdaptiveCorrection`
and `AutoPresetSelector` carry ~100 lines each. Do not copy it back here.

```bash
./build.sh            # → build/Eqlume.app
./build.sh install    # also copies to /Applications — the normal deploy step
```
Plain `swiftc`, no Xcode project. macOS 26+, Apple Silicon. (The `@available(macOS 14.2, *)`
annotations in source are stale; the build target is the real floor.) A stable Apple Development
identity keeps TCC permissions across rebuilds; otherwise it signs ad-hoc.

## Things that will bite you

- **MUTED-TAP TEARDOWN INVARIANT.** The tap is *global* and `muteBehavior = .muted`: while it
  exists the whole Mac is silent except EqLume. So `teardownAudioResources()` is idempotent and
  NEVER guarded by `isRunning`, `startCore()` is exception-safe via `defer`, and `stopCore()` has
  no `guard isRunning` early return. A partial start during a hot-plug once left an orphaned tap
  and the Mac stayed silent until the app quit. Do not "simplify" any of that.
- **The name is split in two and must stay split.** Humans see `EqLume`; machines keep the old
  form — `CFBundleIdentifier` `com.gokturkgocen.Eqlume`, executable `Eqlume`, bundle path
  `build/Eqlume.app`, and every UserDefaults key: `Eqlume.activePresetName`, `.autoEnabled`,
  `.didMigrateFromSesEQ`, `.didRegisterLoginItem`, `.enabledOutputDeviceUIDs`, `.hasSeenOnboarding`,
  `.language`, `.pinnedPresets`. Renaming the bundle id orphans the App Store record; renaming a
  key silently resets that setting. **Keep this list complete** — it exists to be checked against.
- **A PEQ is only valid for the coupler and target it was fit on.** The Chu II baseline is the
  consensus of 3 AutoEQ fits, all 711/GRAS + Harman IE 2019v2. An earlier baseline mixed a 5128
  measurement with a GRAS target and was wrong in both directions.
- **Never apply the Chu II correction to a speaker.** An IEC-711 coupler correction does not
  transfer to a transducer radiating into a room. That is why `OutputProfile` exists.
- **Corrections cut. No makeup gain.** The volume drop from the Harman bass cut is intentional —
  compensate at system volume, do not "fix" it. A suggestion with +12 dB peaks needing −16 dB of
  preamp was actively unpleasant. Boost is the last resort, never the first move.
- **Nothing may dress a non-answer as an answer.** Every detection step can decline; the fallback
  is `.natural` (the measured baseline), never `.pop`, which is not neutral — it lifts 80 Hz.
- **Apple Silicon shares one device ID** between built-in speakers and the 3.5 mm jack, so a
  headphone unplug changes only `kAudioDevicePropertyDataSource` (`ispk`↔`hdpn`), with no
  default-device change. `updateDataSourceListener` is what makes plug/unplug work.
- **Only HTTP-200 outcomes may be cached.** A cached timeout once stuck Scorpions on the audio
  classifier for a whole session.
- **Turkish/Azerbaijani name keys must map `ı`→`i` and `ə`→`e` by hand** (`turkicNameKey`).
  Foundation's diacritic folding does not touch either; two arabesk list entries were dead for
  months because of it.

## Architecture in one pass

- **Which outputs get EQ'd** (`AudioEngine.shouldProcessForCurrentDevice`): the built-in jack
  always (Chu II profile — the measured combo); built-in speakers never (Apple's DSP is left
  alone); anything else opt-in per device UID, then the desk-speaker profile. Caveat: the opt-in
  list is one flat set, so any opted-in device gets the speaker baseline — headphones on a USB DAC
  would get the wrong curve. Add a per-device profile picker when that matters, not before.
- **Baseline is per-device and that is the whole design.** Presets store only a genre delta;
  `EQPreset.resolved(baseline:)` folds the profile's baseline in. `AudioEngine.resolvedPreset` is
  what both the EQ and the drawn curve must use, and the curve cache key includes the profile.
- **Genre deltas are engineering judgment, not measurement** (≤ ±4 dB). Say so wherever documented.
- **Detection order** (`AutoPresetSelector`): pinned track → pre-fetch cache → local artist lists →
  classical work title → catalog (MusicBrainz album votes, then artist votes, then iTunes) → audio
  classifier → `.natural`. The catalog step distinguishes "no data" from "could not reach it" and
  refuses to downgrade to a weaker source on the latter.
- **The classifier's taxonomy has a hole that cannot be worked around**: Discogs-EffNet's 400
  styles contain no Turkish, Anatolian, Azerbaijani, Caucasian or Middle-Eastern label at all. It
  cannot name that material even in principle. This is why measurement-driven correction exists.
- **Localization**: strings are inline (`loc.t("English", "Türkçe")`), no key table.
  `EQPreset.name` is NEVER localized — theming, UserDefaults and pins all key on it; `displayName`
  is for display only. Detection state is structured, not parsed out of a rendered line.
- **UI**: one preset chip only (`natural`) — the manual grid was removed as clutter, and tapping
  the chip disables auto. A new preset needs a line in `Theme.family(forPresetName:)` or it gets no
  accent. The settings panel is an inline button panel, not a SwiftUI `Menu` (which renders
  unreliably in a popover). `"Why this genre?"` (`!APP_STORE`) surfaces `lastDetection`.
- **Startup**: login item registered once; auto detection forced ON at every launch. Not tidiness —
  one tap on the only chip in the interface disabled detection for four days unnoticed.

## Measurement-driven correction (`!APP_STORE`)

`SpectrumMeasurement` accumulates a long-term average spectrum of the pre-EQ tap per artist, into
`~/Library/Application Support/Eqlume/spectrum-measurements.json`. `AdaptiveCorrection` turns it
into ≤3 peaking bands with no external reference, by separating the broad tilt (the music) from
narrow deviations (the recording). Both files document their own method and their guards in full.

Two rules for anyone touching it:
- **The store is in HERTZ, never in FFT bins.** The first version wiped everything on a sample-rate
  change and destroyed ten days of measurement — and the tests had frozen that in as a feature.
- **It is NOT wired to audio.** Validated on synthetic spectra only; it has never run on a real
  measurement. Read the JSON, review the proposals, *then* wire it.

## Permissions the user grants once

Audio Recording (first EQ enable); Automation for Spotify/Music/Chrome/Safari; in Chrome, View →
Developer → "Allow JavaScript from Apple Events" for the YT Music DOM read. Spotify pre-fetch
(`!APP_STORE`) needs a Client ID, redirect URI `http://127.0.0.1:38123/cb`, Premium.

## App Store

Live as **EqLume 1.0, free, since 2026-07-29** (`id6793070613`), from the `APP_STORE` flavor of
build 4. Two flavors from one tree via `#if !APP_STORE`; the store build omits the CC BY-NC-SA
model and the Spotify OAuth path, and `scripts/preflight-appstore.sh` asserts both against the
built binary.

**Rejection lesson — Guideline 2.4.5(i):** build 3 was rejected for *declaring* entitlements the
store flavor never uses. Apple reads the declaration, not the code paths. `build.sh` and the
preflight script both re-assert this via `codesign -d --entitlements` so it cannot regress quietly.
`scripts/package-appstore.sh` reads the version from `Info.plist` — do not hardcode it again.

**Everything since build 4 is unreleased** — most of the detection work, pinning, measurement and
the startup behaviour. A submission needs `CFBundleVersion` > 4.

## Discoverability

`open-source-mac-os-apps` #1243 and `awesome-mac` #2500 are open. **`awesome-macOS` was abandoned
by the user's decision on 2026-08-13**, after #975 and #993 were both closed with no comment in
multi-PR sweeps; that repo closes any PR replacing its template, and its written rule is that an
open-source entry's primary link goes to the app's **website** (source repo only if there is none).
**EqLume has no website**, which is what closes the door on that format — a project page reopens it.
Show HN, r/macapps, r/headphones, AlternativeTo and Product Hunt are the user's to post.

## Honest state

Shipping and functionally complete: process-tap audio path, per-device profiles, detection with
pinning, themed popover with live spectrum and drawn curve.

Not done:
- The desk-speaker baseline has never had its ear-tuning pass.
- `AdaptiveCorrection` is unwired and unproven on real data.
- Not started: album art in the now-playing card, a user master bass/mid/treble trim, a genuinely
  measured baseline for a specific speaker set, per-device profile choice.
