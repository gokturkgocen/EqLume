# EqLume

System-wide equalizer for macOS, originally tuned for the **Moondrop Chu II IEM on the MacBook
Air M4 3.5 mm headphone jack** (usable with any headphones). Picks a genre-appropriate EQ preset
from whatever is playing. Author: Göktürk Göcen. MIT for the app's own code; the bundled ML model
is CC BY-NC-SA 4.0 (see LICENSE / THIRD-PARTY.md).

**Spelling of the name — one rule.** Everything a human reads says **`EqLume`** (capital L):
`CFBundleName` / `CFBundleDisplayName`, README, App Store listing, marketing. Everything a
machine keys on keeps the old single-capital form and must NOT be renamed: `CFBundleIdentifier`
= `com.gokturkgocen.Eqlume`, `CFBundleExecutable` = `Eqlume`, the built bundle path
`build/Eqlume.app`, and every UserDefaults key — currently `Eqlume.activePresetName`,
`.autoEnabled`, `.didMigrateFromSesEQ`, `.didRegisterLoginItem`, `.enabledOutputDeviceUIDs`,
`.hasSeenOnboarding`, `.language`, `.pinnedPresets`. Renaming the bundle id orphans the App Store
record; renaming a defaults key silently resets that setting. Keep this list complete — it exists
to be checked against, and an incomplete one cannot do that job.

## Build / run

```bash
./build.sh            # builds build/Eqlume.app (Apple Development identity if present, else ad-hoc)
./build.sh install    # also copies to /Applications — the normal deploy step
```
- Plain `swiftc`, no Xcode project; all `Sources/*.swift` compiled together.
- A stable **Apple Development** identity keeps TCC permissions across rebuilds; without one it
  signs ad-hoc so anyone can build with no Apple account (`SIGN_ID=... ./build.sh` to override).
- Requires **macOS 26.0+**, Apple Silicon. The `@available(macOS 14.2, *)` annotations in source
  are stale minima; the real floor is the build target / `LSMinimumSystemVersion`.
- Menu-bar only (`LSUIElement`), no dock icon.

## Audio path

- System audio is captured with a **Core Audio process tap** (`muteBehavior = .muted`) plus a
  private **aggregate device**, run through **AVAudioUnitEQ**, and played back to the real output.
  No virtual driver, no kernel extension — a free Apple ID is enough to build it.
- **MUTED-TAP TEARDOWN INVARIANT — do not break.** The tap is *global*: while it exists the whole
  Mac is silent except EqLume. So `teardownAudioResources()` is idempotent and is NEVER guarded by
  `isRunning`; `startCore()` is exception-safe (a `defer` tears everything down on a partial-start
  throw); `stopCore()` always tears down with no `guard isRunning` early return. A start that
  failed mid-way during a device hot-plug once left an orphaned muted tap — `isRunning=false` but
  the tap alive, so every later `stopCore` no-op'd — and the Mac stayed silent until the app quit.
- On Apple Silicon the built-in speakers and the 3.5 mm jack **share one device ID**, so a
  headphone unplug flips `kAudioDevicePropertyDataSource` (`ispk`↔`hdpn`) with NO default-device
  change. `AudioEngine.updateDataSourceListener` watches that so `reconcile()` runs on plug/unplug.

### Which outputs get EQ'd (`AudioEngine.shouldProcessForCurrentDevice`)

1. **Built-in 3.5 mm jack** (`hdpn`) → always on, `OutputProfile.chuII`. This is the measured combo.
2. **Built-in speakers** (`ispk`) → never processed; Apple's own DSP is left alone.
3. **Anything else** (monitor speakers, USB DAC, Bluetooth) → **opt-in per device**, keyed by Core
   Audio device UID (`DeviceEQPolicy`, `Eqlume.enabledOutputDeviceUIDs`, stable across reconnects),
   then runs `OutputProfile.desktopSpeakers`.

Caveat to fix only when it bites: the opt-in list is one flat set, so ANY opted-in non-jack device
gets the speaker baseline — headphones on a USB DAC would get the wrong curve. Add a per-device
profile picker at that point, not before.

## Presets (`EQPreset.swift`, `OutputProfile.swift`)

- **The baseline is per-device, and that is the whole design.** Music presets store ONLY their
  genre delta with `usesDeviceBaseline = true`; `EQPreset.resolved(baseline:)` folds the profile's
  baseline in before the preset reaches the EQ node. `.chuII` → `chuIIBaseline`,
  `.desktopSpeakers` → `desktopSpeakerBaseline`. `flat` and `voice` are standalone and behave
  identically everywhere. `AudioEngine.resolvedPreset` is what the EQ and the drawn curve must both
  use; the curve cache key includes the profile (`StatusBarController.curveKey`) because one preset
  name resolves to different curves on different devices.
- **Chu II baseline**: 7 filters, the consensus of 3 independent AutoEQ fits (all 711/GRAS-RA0045
  + Harman IE 2019v2). **A PEQ is only valid for the coupler and target it was fit on.** An earlier
  hand-set baseline mixed a 5128 measurement with a GRAS-Harman target, and was wrong in both
  directions — no ~6 kHz presence lift, and it *boosted* a 10 kHz shelf the Chu II needs cut.
- **Never apply the Chu II correction to a speaker.** An IEC-711 coupler correction does not
  transfer to a transducer radiating into a room. `desktopSpeakerBaseline` is a separate,
  class-typical 2.1-desk correction — **not** a measurement of any specific set, so it is meant to
  be trimmed by ear (bass thin → 80 Hz toward −1; treble harsh → 3 kHz toward +1.5).
- Genre deltas are **engineering judgment, not measurement**, and stay small (≤ ±4 dB). Say so
  wherever one is documented.
- `globalGain = preampOffsetDB` (negative, prevents clipping). **No makeup gain** — the volume drop
  from the Harman bass cut is intentional; compensate at the system volume. Do not "fix" it.
- **Corrections cut; they do not pile on gain.** A suggestion with +12 dB peaks needing −16 dB of
  preamp was actively unpleasant. Boost is the last resort, never the first move.
- `maxBands = 12` (7 baseline + up to 3 delta). Measured correction will need more; raise it there.

## Detection: which preset, per track (`AutoPresetSelector.swift`)

Resolved in this order. **Every step may decline**; nothing in this chain is allowed to dress a
non-answer as an answer.

0. **Pinned track** (`PinnedPresets`, `Eqlume.pinnedPresets`) — an (artist, title) → preset-name
   map the user sets from the settings panel. Outranks everything below, including a genre hint
   from the player, and skips the chain entirely. Detection is a guess by construction; for the few
   records played on repeat this is where the answer is stated once. Key is the lowercased
   `artist||title` the player reports, so a different upload of the same song is a different pin.
   The stored value is `EQPreset.name` (the stable key, never `displayName`); an unknown name
   resolves to nil rather than crashing. Tag `★` → source "sabit / pinned".
1. **Pre-fetch cache** — the Spotify/YT Music queue lookahead already resolved this track.
2. **Local artist lists** (`!APP_STORE`) — arabesk and Anatolian/Caucasian folk singers, matched on
   a normalized name. For these the catalog is not thin but *confidently wrong*: Apple files the
   Azerbaijani xalq mahnısı "Evlərinin önü yonca" as **Pop** with the artist matching exactly, so
   the check that rejects bad hits waves it through. **Normalization must map `ı`→`i` and `ə`→`e`
   by hand** (`turkicNameKey`); Foundation's diacritic folding handles ş/ç/ğ/ö/ü but not those two,
   and until that was fixed two of the eleven arabesk entries could never match.
3. **Classical work titles** (`looksLikeClassicalWork`) — offline, before any lookup, because on a
   classical upload the artist field holds a performer no catalog has heard of while the title
   states the piece exactly. Qualifies on an opus/thematic-catalogue number (`Op. 9`, `BWV 846`,
   `K. 331` — single-letter catalogues require their period), or a classical form word TOGETHER
   with a movement number or a stated tonality. Tonality alone is not enough: "In A Major Way" is a
   soul album. Tag `♯` → source "eser adı / work title".
4. **Catalog** (`resolveGenre`), best source first — see below.
5. **Audio classifier** (`GenreClassifier`) — deferred ~4.5 s so the analysis ring holds the
   current track. Catalog-independent.
6. **Nothing** → `.natural`, the measured baseline. There is deliberately no "default to pop":
   pop is not neutral, it lifts 80 Hz.

### The catalog step

`resolveGenre` returns **three** outcomes and the distinction is load-bearing: `.resolved`,
`.noData` (every source answered, none knew the track), `.unavailable` (a source we trust more
could not be reached). On `.unavailable` the chain does NOT fall through to a weaker source and
does NOT retry with a name parsed out of the title — it defers to audio analysis, which needs no
network. Collapsing those two into one optional is how a single timeout turned Andrea Bocelli
(`classical` 6 / `classical crossover` 3 / `pop` 2 in MusicBrainz) into iTunes' answer of Pop.

Sources, in order:

- **MusicBrainz album votes** (`albumGenres`) — the release group's own votes. Artist votes
  describe a career, which is wrong whenever one record departs from it: Tame Impala is
  psychedelic rock by career, but "Dracula" is on *Deadbeat*, whose votes are dance-pop plus
  house/techno → EDM. Only a **plain studio album** counts (primary type `Album`, no secondary
  type) — the same recording also sits on compilations, remix singles and DJ-mixes whose votes
  describe the package. No `tags` fallback here: release-group tags are full of non-genres
  ("plattentests.de", "offizielle charts"). Coverage is thinner than artist coverage, so this is a
  preference, not a replacement.
- **MusicBrainz artist votes** (`artistGenres`) — count-weighted into a family via
  `mapWeightedGenresToPreset` + `genreKeywordRules`. Free, no key, ≤1 req/s throttle, cached per
  artist. Right where iTunes is wrong at the artist level (Buckethead → "Electronic", Dire Straits
  → "Pop"). Tag `♪`. The displayed genre name is the strongest vote **inside the winning family**,
  not overall, or the label contradicts the preset beside it.
- **iTunes** (`GenreLookupService`) — one genre per track, verified with `artistNamesRoughlyMatch`.
  No marker → source "katalog". Fetches 5 results and picks the first whose artist actually
  matches: with `limit=1` a cover or feat. upload can outrank the original, fail verification, and
  sink the whole lookup.
- **NOT Spotify** — it removed `genres` from the Web API in 2024 (verified live). `SpotifyAPI` is
  kept only for now-playing and queue pre-fetch.

Rules this step earned the hard way, each still enforced:

- **`mapGenreToPreset` returns an optional.** Its fallback used to be `.pop`, which turns "I don't
  recognise this" into a confident answer. NB: pop was *only* reachable through that fallback, so
  removing it silently stopped plain "Pop" mapping to anything until an explicit rule was added at
  the end. Known divergence, harmless so far: this function checks EDM before pop ("Dance Pop" →
  EDM) while `genreKeywordRules` deliberately checks pop first.
- **A search hit must actually be the artist.** `artistNamesRoughlyMatch` accepts only ANCHORED,
  DIRECTIONAL partial matches: when the name we want is shorter it may be a prefix or suffix of the
  candidate ("Chopin" in "Fryderyk Chopin"); when the *candidate* is shorter it must be a
  whole-token prefix, and a single-token candidate additionally needs a collaboration word after it
  ("Sezen Aksu" for "Sezen Aksu feat. X", but not "Timeless" for "Timeless Serenade"). An
  unanchored substring let a Dallas metal band called "Nocturne" answer for a Chopin nocturne.
- **MusicBrainz must be able to say "I don't know."** `searchArtistMBID` has no
  `?? artists.first` fallback; unknown → `.noMatch`. Its one narrow replacement: the TOP hit is
  accepted when the surname token AND the given-name initial both match, which recovers aliases the
  normalizer cannot ("Frédéric Chopin" is indexed as "Fryderyk Chopin") without letting every
  same-surname stranger through ("Gülyanaq Məmmədova" for "Nərminə Məmmədova").
- **Only HTTP-200 outcomes may be cached.** A timeout cached as a permanent miss once stuck
  Scorpions on the audio classifier for a whole session. `get()` retries once and backs off on 503,
  because resolving one track can cost four requests through a 1 req/s throttle.
- **`splitArtistTitle` is a last resort, and it cuts in the wrong places.** It exists because
  YouTube channels put the uploader in the artist slot with the real artist in the title. It splits
  on spaced separators first, then a bare dash guarded so hyphenated names survive (Jay-Z, T-Pain,
  Blink-182 do not split) — and it refuses to split when the text left of the dash is a single
  letter, because "Nocturne in E-flat Major" is not "Artist - Title".
- iTunes labels all Turkish folk simply **`Halk`**, and MusicBrainz's only vote on Neşet Ertaş is
  **`uzun hava`**. Short forms have to match, or the whole tradition falls through to a preset with
  no delta.
- Apple's **`World`/`Worldwide`** is a storefront bucket, not a genre; the local build rejects it.

Now-playing sources: Spotify Web API (OAuth, queue pre-fetch), YouTube Music (browser DOM via
AppleScript `execute javascript`, queue pre-fetch), Apple Music and browsers (AppleScript).
`cleanMusicTitle` strips tempo/edit tags (`slowed`, `nightcore`, `bass boosted`, remaster/live/…)
before lookup so variant uploads match the original recording.

**Transport controls** (`PlaybackController`): the popover's ⏮ ⏯ ⏭ route to whatever is actually
producing audio, resolved at press time via `AudioSourceMonitor.currentSourceBundleID()`. Spotify
and Apple Music use AppleScript transport verbs — **not** the Web API, so no extra OAuth scope or
Premium dependency. YT Music uses a JS click in `ytmusic-player-bar`.

## Audio classifier (`GenreClassifier.swift`)

- **Model**: Discogs-EffNet (MTG-UPF), ONNX → CoreML. Input `[1,128,96]` mel, output 400 styles.
- **Mel** (`MelSpectrogram.swift`, vDSP) is **verified bit-exact against Essentia's
  TensorflowInputMusiCNN** (max diff 0.0 in Python; the Swift port self-tests to ~5e-6 on load).
  Regeneration: `ml-pipeline/README.md`.
- **Its taxonomy has a hole that cannot be worked around.** Those 400 styles contain **no** Turkish,
  Anatolian, Azerbaijani, Caucasian or Middle-Eastern label at all (checked against
  `discogs_styles.txt`). The model cannot name this material even in principle; its closest answers
  are `Folk` → `.acoustic` or `.world`. This is why measurement-driven correction exists.
- **`Modern Classical` is filed under the Electronic parent**, so parent-genre mapping sent solo
  piano to EDM and lifted its bass. The `electronic` branch checks for a `classical` style first.
- **Voice needs two guards, because sparse acoustic music reads as room tone to this model.**
  (a) `.voice` may only win if the single top style is itself a voice style — summed probability
  across 16 `Non-Music---*`/`Children's---*` styles otherwise lets a slowed track become a podcast.
  (b) On music-only players (`musicOnlyBundles`: Spotify, Apple Music, YT Music) `.voice` is
  refused outright via `classify(allowVoice:)`, because there it is always a misfire — a
  string-heavy instrumental classical track came out as "Vokal / Diyalog" with a `Non-Music` style
  genuinely on top. A browser tab keeps voice: a YouTube talk really can be speech. Nothing is lost,
  since real speech on those services carries a catalog genre that resolves long before analysis.
  Do not widen `.voice` membership without re-checking both.
- **Local confidence guard** (`!APP_STORE`): families are uneven in size, so the local build scores
  each family's three strongest styles (1 / 0.5 / 0.25) instead of letting a large family win on
  accumulated noise. Below the confidence/margin bar it keeps the neutral preset and shows
  `Genre uncertain` / `Tür belirlenemedi` — the honest outcome when the model is confused.

## Measurement-driven correction (`!APP_STORE`, not yet wired to audio)

For music nothing can name — a violinist with no catalog presence anywhere — stop naming it and
correct the recording instead.

- **`SpectrumMeasurement`** — long-term average spectrum of the PRE-EQ tap, per artist, across
  sessions, in `~/Library/Application Support/Eqlume/spectrum-measurements.json`. 8192-point FFT
  (5.9 Hz bins at 48 kHz: at 2048 there are too few bins inside one ERB down at 50 Hz). Samples 4 s
  every 5 s, only while `audio.isRunning` — i.e. headphones in the jack.
  **Stored on a 1/24-octave axis in HERTZ, never on FFT bins.** The first version accumulated per
  bin and wiped everything when the output changed sample rate, on the correct observation that bin
  *k* is a different frequency at 44.1 than at 48 kHz. The observation was right and the
  consequence was indefensible: ten days of measurement destroyed the first time a device switched
  rate — and the test suite had frozen that behaviour in as though it were a feature. Bins are an
  implementation detail; hertz are not.
- **`AdaptiveCorrection`** — that spectrum into at most 3 peaking bands, with **no external
  reference**. Every documented failure of automatic spectral matching (arbitrary reference,
  loudness dependence, heavy-handedness, song-specific nonsense) follows from having one. The
  reference here is the recording's own spectrum smoothed over 3× the ear's ERB (Glasberg & Moore,
  `24.7·(4.37·f_kHz + 1)`), and the anomaly is `1×ERB-smoothed − 3×ERB-smoothed`. Subtracting a
  smoothed copy of a curve from itself cancels any common offset, so playback level provably cannot
  change the result — there is a test for exactly that.

  The separation it relies on: a spectrum's broad **tilt is the music** (bozlak has no bass because
  no instrument plays bass — "fixing" that would add the very boost this app refuses), while its
  narrow deviations are the **recording** (resonance, hiss shelf, mic colouration). Four guards,
  each found by testing rather than reasoning:
  1. **One scale is not enough** — with the reference at exactly 1 ERB, a resonance about 1 ERB
     wide erases its own detection (a 7 dB synthetic peak measured 1.15 dB). Hence 1 vs 3.
  2. **Nearest-bin log resampling builds a staircase** at the low end, and a band-pass operator
     reports each step's curvature as resonance. Cells with no bin of their own are interpolated.
  3. **Zeroing the anomaly outside the band manufactures an edge**, and the first surviving point
     reads as a peak against it. The band restricts candidate SELECTION only.
  4. **Curvature in the tilt is not a resonance** — the knee where a bass rolloff begins makes a
     real broad lobe. Rejected by width: wider than 60 % of the reference window is timbre.

  Bounds: cuts to −3 dB, boosts only to +1.5 (a notch does not ring); 0.2–1.5 octave bandwidth;
  ≥0.5 octave between filters; gain traded away as a filter narrows (AutoEq's high-Q/high-gain
  penalty); detection band 100 Hz–10 kHz (below ~100 Hz the ERB is most of an octave, so resonance
  and timbre stop being separable in principle); ≥2000 frames and ≥3 distinct titles before
  proposing anything. Every proposal is checked against the biquad magnitude it will actually
  realise and dropped if it does not reduce the anomaly.
- **Status: validated on synthetic spectra only** (finds a 0.15-octave resonance and a hiss shelf;
  ignores a 2-octave hump, a pure tilt and a steep rolloff; level-invariant). It has never run on a
  real measurement. Read the JSON, review the proposals, *then* wire application.

## Startup: ready without being switched on

- **Login item registered once** (`Eqlume.didRegisterLoginItem`), so a later deliberate "off" in
  the settings panel is not overridden on the next launch.
- **Auto detection is forced ON at every launch**, not restored from the last session. Not
  tidiness: `selectPreset` turns auto off and persists it, and the popover shows exactly one preset
  chip — so one tap on the only chip in the interface permanently killed detection, and it stayed
  off for four days unnoticed. The toggle still works for the session.

## Permissions (one-time, user-granted)

- **Audio Recording** — first EQ enable.
- **Automation** → Spotify / Music / Chrome / Safari, for now-playing. Entitlement
  `com.apple.security.automation.apple-events`; the settings panel has a test for it.
- **Chrome**: View → Developer → "Allow JavaScript from Apple Events", for the YT Music DOM read.
- **Spotify pre-fetch** (`!APP_STORE`): paste a Client ID from the developer dashboard, redirect
  URI `http://127.0.0.1:38123/cb`, Premium account, tokens in Keychain.

## Localization (`Localization.swift`)

- Runtime language switch, English default. `Loc.shared` is a `@MainActor ObservableObject`;
  `L` is a non-actor mirror for use off the main actor. Strings are inline — `loc.t("English",
  "Türkçe")` — so there is no key table and no missing-key bugs.
- **`EQPreset.name` is never localized.** It is load-bearing: theming matches on it, UserDefaults
  persists it, pins store it. `displayName` is the localized label, for display only.
- **Detection state is structured, not parsed.** The view localizes from `lastArtist/lastTitle/
  lastSourceApp/lastSourceKind/lastStatus`. An earlier version parsed Turkish substrings out of the
  rendered detection line and broke the moment those strings were translated.

## UI (SwiftUI popover)

Menu-bar icon → `NSPopover` hosting `PopoverView`; `StatusBarController` owns the model and pushes
state into `EQViewModel`.

- **Accent colour follows the active preset's family** (`PresetFamily.accent`) and animates on
  change. A new preset needs a line in `Theme.family(forPresetName:)` or it has no accent.
- **EQ curve** from `FrequencyResponse` (combined RBJ-biquad magnitude); **live spectrum** from
  `SpectrumAnalyzer` (2048-pt, 40 log bands — distinct from `SpectrumMeasurement`'s 8192), driven
  by a 30 fps timer only while the popover is open and EQ is running.
- **Only ONE preset chip is shown** (`EQPreset.natural`). The other presets still exist and auto
  still picks them; the manual grid was removed as clutter. Do not reintroduce it — but remember
  that tapping the chip disables auto (see Startup).
- **Pinning UI is an `NSAlert` + `NSPopUpButton`**, not a grid: a rare deliberate act should not
  occupy screen space permanently.
- **"Why this genre?"** (`!APP_STORE`) shows `lastDetection` — which source answered and, for the
  classifier, its top Discogs style with confidence. That string was computed on every resolve and
  read nowhere, so a wrong genre could only be diagnosed by re-deriving the whole chain by hand.
  Markers: `♪` MusicBrainz, `♯` work title, `★` pinned, bare `[name]` iTunes, `[style · NN%]` the
  classifier.
- The settings panel is an inline button panel behind a `gearshape` toggle — **not** a SwiftUI
  `Menu`, which renders unreliably inside a popover.

## Distribution — Mac App Store

- **Live as "EqLume" 1.0, free, since 2026-07-29** (`apps.apple.com/app/id6793070613`). The store
  build is the `APP_STORE` flavor of build 4.
- **Two flavors, one tree**, split by `#if !APP_STORE`. The store build omits (i) the Discogs-EffNet
  model — CC BY-NC-SA is the wrong license posture for a store binary — and (ii) the Spotify OAuth
  path. `scripts/preflight-appstore.sh` asserts both by inspecting the built binary.
- **Rejection lesson — Guideline 2.4.5(i), entitlements minimalism.** Build 3 was rejected for
  declaring `network.server` and `keychain-access-groups` that the store flavor does not use.
  **Apple reads the declared entitlements, not the code paths.** `build.sh` and the preflight script
  both re-assert this via `codesign -d --entitlements`, so it cannot regress silently.
- `scripts/package-appstore.sh` reads the version out of `Info.plist` — do not hardcode it again.
- **Everything since build 4 is unreleased**, which is now most of the detection work, pinning,
  measurement and the startup behaviour. A submission needs `CFBundleVersion` > 4.

## Discoverability

- `serhii-londar/open-source-mac-os-apps` **#1243 open** (a permanently "pending" commit status
  there is normal). `jaywcjlove/awesome-mac` **#2500 open**.
- `iCHAIT/awesome-macOS` — **abandoned by the user's decision, 2026-08-13**, after #975 and #993
  were both closed with no comment inside multi-PR sweeps. Two things were learned there and are
  worth keeping: that repo closes any PR that replaces its template wholesale, and its written rule
  is that an open-source entry's **primary link goes to the app's website** (source repo if there is
  no website), with the OSS badge on the source — #993 used the App Store as primary. The merges in
  those same sweeps follow that rule exactly, so the sweeps are not blind.
- **EqLume has no website of its own**, only a store listing and a repo, which is what closes the
  door on that entry format. A project page would reopen it.
- Remaining channels are the user's to post: Show HN, r/macapps, r/headphones, AlternativeTo
  (blocks accounts younger than 7 days), Product Hunt.

## Status

Shipping on the Mac App Store. Functionally complete: process-tap audio path, per-device profiles,
genre detection with pinning, themed popover with live spectrum and drawn curve.

Not done, honestly:
- The `desktopSpeakerBaseline` ear-tuning pass has never been made.
- `AdaptiveCorrection` is unwired and unproven on real data.
- Open ideas, not started: album art in the now-playing card, a user master bass/mid/treble trim,
  a genuinely measured baseline for a specific speaker set, per-device profile choice.
