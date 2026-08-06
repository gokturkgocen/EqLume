# Eqlume

![Platform](https://img.shields.io/badge/platform-macOS%2026-000000?logo=apple&logoColor=white)
![Arch](https://img.shields.io/badge/arch-Apple%20Silicon-555)
![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)
[![Latest release](https://img.shields.io/github/v/release/gokturkgocen/Eqlume)](https://github.com/gokturkgocen/Eqlume/releases/latest)
[![License](https://img.shields.io/badge/license-MIT%20(code)-blue)](LICENSE)
[![Built with Claude Code](https://img.shields.io/badge/built%20with-Claude%20Code-D97757?logo=anthropic&logoColor=white)](https://claude.com/claude-code)

**A system-wide equalizer for macOS that listens to what you're playing and picks the right EQ curve for you — automatically.**

<p align="center">
  <img src="assets/demo.gif" width="380" alt="Eqlume auto-detecting the genre of each track and re-theming the popover live as songs change">
</p>

Eqlume is a lightweight menu-bar app that applies a real, transparent equalizer to your Mac's audio system-wide. It runs entirely on-device: it captures system audio through a Core Audio process tap, runs it through a native `AVAudioUnitEQ`, and plays it back through your real output device — no virtual audio driver, no kernel extension, no background service to babysit. When automatic mode is on, Eqlume figures out the genre of the current track and switches to a matching preset on the fly.

> The bundled correction baseline was measured and tuned for the **Moondrop Chu II** in-ear monitor, but that's just the default. Eqlume works with any headphones — every genre preset is a small delta on top of a single baseline curve you can treat as neutral, and the whole EQ is a set of standard parametric/shelf filters. Nothing about it is locked to one pair of earphones.

## Screenshots

<p align="center">
  <img src="assets/app-store/01-follows-your-music.png" width="46%" alt="Eqlume automatic EQ product view">
  &nbsp;&nbsp;
  <img src="assets/app-store/02-see-the-sound.png" width="46%" alt="Eqlume live spectrum product view">
</p>

<p align="center"><em>Same app, two tracks. Eqlume identifies the genre on its own — Queen → <strong>Rock</strong> (from the queue pre-fetch), Mahmut Orhan → <strong>EDM</strong> (from the catalog) — and the whole popover re-themes to match. No manual switching, no fiddling.</em></p>

## Features

- **System-wide EQ** applied to all audio, not just one app.
- **Automatic genre detection** with per-genre presets — hip-hop, trap, EDM, drum & bass, R&B, pop, K-pop, rock, metal, jazz, classical, blues, latin, reggae, indie, ambient, and more (21 built-in presets in total).
- **Menu-bar only** (`LSUIElement`) — no dock icon; opens a compact SwiftUI popover.
- **Bilingual UI** — English by default, Turkish selectable at runtime from the settings panel.
- **Live spectrum analyzer** (2048-point FFT, 40 log-spaced bands) and a **rendered EQ response curve** for the active preset.
- **Genre-reactive UI**: the popover's accent color follows the active preset family (rock red, EDM blue, metal chrome, …) and animates on genre change.
- **Transport controls** (previous / play-pause / next) that route to whichever player is currently producing audio — Spotify, Apple Music, or YouTube Music.
- **On-device audio-content classifier** (a CoreML model) as a fallback when catalog lookups can't identify a track — nothing about your listening is sent anywhere for classification.
- **Per-output profiles**: the built-in 3.5 mm jack gets the in-ear correction; other outputs (e.g. desk speakers on a monitor) are opt-in per device and get a desktop-speaker baseline instead. Built-in speakers are left to Apple's own DSP.
- A peak limiter at 0 dBFS sits after the EQ to catch any transient from an EQ boost.

## How it compares

| | **Eqlume** | eqMac | SoundSource | Boom 3D |
|---|---|---|---|---|
| Picks the preset for you (per-track genre detection) | **✅** | ❌ | ❌ | ❌ |
| System-wide EQ | ✅ | ✅ | ✅ | ✅ |
| No virtual audio driver / kernel extension | **✅** (Core Audio process tap) | ❌ | ❌ | ❌ |
| Works fully on-device | ✅ | ✅ | ✅ | ✅ |
| Open source | **✅** (MIT, app code) | ✅ | ❌ | ❌ |
| Price | **Free** | Free / paid tiers | Paid | Paid |

The differentiator is the first row: other equalizers give you bands and presets to manage — Eqlume identifies what's playing and applies a matching curve on its own.

## How it works

<p align="center"><img src="assets/architecture.png" width="100%" alt="Eqlume architecture: audio path (system audio → Core Audio tap → AVAudioUnitEQ → jack) and the genre→preset pipeline (MusicBrainz → iTunes → on-device CoreML classifier)"></p>

**Audio path.** Eqlume creates a global Core Audio process tap (`muteBehavior = .muted`) plus a private aggregate device. The tapped system audio is fed through an `AVAudioUnitEQ` node and played back to the real output device. Because it uses the public Core Audio tap API, there's no virtual driver or kernel extension to install.

**Where the EQ applies — and with which baseline.** Correction curves are not transferable between transducers, so Eqlume picks one per output:

- **Built-in 3.5 mm headphone jack** → always on, with the Chu II → Harman in-ear correction. On Apple Silicon the speakers and the jack share one device ID, so Eqlume watches the Core Audio data-source property to react correctly to plugging and unplugging.
- **Built-in speakers** → never processed; Apple's own DSP already tunes them.
- **Any other output** (monitor speakers over HDMI, USB DAC, Bluetooth …) → **opt-in per device** from the settings panel, remembered by device UID. Once enabled it uses the **desktop-speaker** baseline (tames the sub hump and the 200 Hz desk/cabinet boxiness, lifts the recessed presence region) instead of the in-ear one — an IEC-711 coupler correction has nothing to do with a speaker radiating into a room.

**How it picks a preset.** For each track, automatic mode resolves a genre in this order:

1. **MusicBrainz** (primary) — community genre votes with counts, weighted into a preset family. Free, no API key. Accurate at the artist level where other catalogs mislabel.
2. **iTunes Search API** (fallback) — the track's primary genre, verified against the artist name to reject confident wrong matches.
3. **On-device CoreML classifier** (catalog miss) — when neither catalog can identify the track, Eqlume classifies from the audio content itself using a bundled model, independent of any catalog.
4. If everything else fails, it defaults to a pop preset.

Now-playing information comes from Spotify (Web API, with optional queue pre-fetch), YouTube Music (browser DOM), and Apple Music / browsers (AppleScript).

**The EQ curves.** Every music preset is a shared measurement-derived baseline plus a small genre-specific delta (a few dB at one or two points). The baseline targets the Harman in-ear 2019v2 response and is the consensus of three independent AutoEQ fits (all measured on IEC-711 / GRAS-class couplers against the same target). Presets use a negative preamp offset and apply no makeup gain, so the limiter rarely has to work — expect a small, intentional volume drop you can make up at the system volume. Speech / dialogue uses a separate intelligibility-focused preset rather than the music target.

## Requirements

- **Apple Silicon Mac** (arm64).
- **macOS 26.0 (Tahoe) or later** — the build target and bundle minimum are both pinned to 26.0.
- Xcode Command Line Tools with the macOS 26 SDK (to build).
- No Apple Developer account needed — see below.

## Download

Grab the latest `Eqlume-macos.zip` from [Releases](https://github.com/gokturkgocen/Eqlume/releases), unzip it, and move `Eqlume.app` to `/Applications`.

The app is ad-hoc signed (no paid Apple Developer account), so macOS Gatekeeper will block it on first launch. To open it once:

**Easiest (Terminal):**

```bash
xattr -dr com.apple.quarantine /Applications/Eqlume.app
open /Applications/Eqlume.app
```

**Or via the GUI:** double-click `Eqlume` → when the warning appears, open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

You only need to do this once. Prefer to build it yourself? See below.

## Build & Install

Eqlume builds with plain `swiftc` — there's no Xcode project to open.

```bash
git clone https://github.com/gokturkgocen/Eqlume.git
cd Eqlume
./build.sh install      # builds and copies Eqlume.app to /Applications
```

`./build.sh` alone just produces `build/Eqlume.app`; adding `install` also copies it to `/Applications`.

For the isolated Mac App Store sandbox build and preflight checks, see
[`APP_STORE_RELEASE.md`](APP_STORE_RELEASE.md). This build intentionally excludes the
non-commercial Discogs-EffNet model while preserving catalog-based automatic presets.

**Signing.** No paid Apple Developer account is required. If you have a local **Apple Development** signing identity (a free Apple ID provides one), the build uses it — re-signing with a stable identity keeps your macOS privacy (TCC) permission grants intact across rebuilds. If you have no signing identity at all, `build.sh` automatically falls back to **ad-hoc signing**, which needs no certificate. You can force a specific identity with `SIGN_ID="Your Identity" ./build.sh`.

**Regenerating the ML model (optional).** A normal build needs nothing from `ml-pipeline/` — the compiled model (`Resources/DiscogsEffNet.mlmodelc`) is already committed. See [`ml-pipeline/README.md`](ml-pipeline/README.md) to regenerate it from the upstream ONNX model.

## Permissions you grant once

The first time you use each feature, macOS prompts you. All are one-time grants:

- **Audio Recording** — required to capture system audio for the EQ. Audio is only processed and sent straight back to your output; it is never recorded to disk or transmitted.
- **Automation** for Spotify / Music / Chrome / Safari — used to read the currently playing track for automatic preset selection, and to send transport commands (previous / play-pause / next) when you use the playback controls.
- **Chrome only**: enable *View → Developer → Allow JavaScript from Apple Events* so Eqlume can read the YouTube Music player state.
- **Spotify pre-fetch (optional)**: connect from the settings panel by pasting a Client ID from your Spotify developer dashboard (redirect URI `http://127.0.0.1:38123/cb`). Tokens are stored in your macOS Keychain.

## Usage

1. Launch Eqlume — a menu-bar icon appears (no dock icon).
2. Click the icon to open the popover, then enable the EQ.
3. Plug in headphones via the 3.5 mm jack — the EQ engages automatically (and disengages on any other output).
4. Leave **automatic mode** on and Eqlume follows the genre of whatever you're playing, or pin the neutral baseline preset from the popover.
5. The popover shows the now-playing track, the detected genre and its source, a live spectrum, and the active EQ curve.

## Built with Claude Code

Eqlume was designed and written end-to-end with [Claude Code](https://claude.com/claude-code) — as a test of how far an AI pair can go on a real, native macOS app rather than a toy. That meant working through the genuinely hard parts, not just boilerplate:

- **Core Audio process taps** (`muteBehavior = .muted` + a private aggregate device) to capture and re-route system audio with no virtual driver or kernel extension.
- An offline **ONNX → CoreML** pipeline for the Discogs-EffNet classifier, with a hand-ported **mel-spectrogram front-end verified bit-exact against Essentia**.
- The **MusicBrainz → iTunes → on-device classifier** genre-resolution chain, its edge-case handling, and this documentation.

If you build with Claude and want to see a complete, shipped example — signal chain, ML, and UI — this repo is one.

## Credits / Third-party

Eqlume bundles a third-party machine-learning model for on-device audio classification: **Discogs-EffNet** by **MTG-UPF** (Music Technology Group, Universitat Pompeu Fabra), from the Essentia model collection. The compiled CoreML model ships in `Resources/DiscogsEffNet.mlmodelc`, and the offline conversion pipeline lives in `ml-pipeline/`.

See [`THIRD-PARTY.md`](THIRD-PARTY.md) for full attribution and license terms of every third-party component.

## License

The application's own source code is released under the **MIT License** — see [`LICENSE`](LICENSE). Copyright © 2026 Göktürk Göcen.

**Important caveat:** the bundled **Discogs-EffNet** model is licensed **CC BY-NC-SA 4.0** (by MTG-UPF). Because the model is redistributed as part of this repository, any redistribution or derivative that includes the model is effectively **non-commercial** and must be shared alike under CC BY-NC-SA 4.0. The MIT license covers only the app's own code, not the bundled model. For a commercial-friendly distribution, remove the model and regenerate or substitute one under compatible terms (see [`ml-pipeline/README.md`](ml-pipeline/README.md)).

---

Made by **Göktürk Göcen**, built with [**Claude Code**](https://claude.com/claude-code) — from the Core Audio tap plumbing and the ONNX→CoreML pipeline to the genre-detection heuristics and this README.
