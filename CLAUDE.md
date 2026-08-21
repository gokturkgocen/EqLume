# EqLume

System-wide equalizer for macOS, originally tuned for the **Moondrop Chu II IEM on the
MacBook Air M4 3.5mm headphone jack** (but usable with any headphones). Auto-selects a
genre-appropriate EQ preset from what's playing. Author: Göktürk Göcen. Open source —
MIT for the app's own code; the bundled ML model is CC BY-NC-SA 4.0 (see LICENSE / THIRD-PARTY.md).

**Spelling of the name — one rule.** Everything a human reads says **`EqLume`** (capital L):
`CFBundleName` / `CFBundleDisplayName`, README, App Store listing, list submissions, marketing.
Everything a machine keys on keeps the old single-capital form and must NOT be renamed:
`CFBundleIdentifier` = `com.gokturkgocen.Eqlume`, `CFBundleExecutable` = `Eqlume`, the
UserDefaults key prefix `Eqlume.*` (`Eqlume.language`, `Eqlume.enabledOutputDeviceUIDs`,
`Eqlume.pinnedPresets`),
and the built bundle path `build/Eqlume.app`. Changing the bundle id would orphan the App
Store record and every stored preference; changing a defaults key would silently reset the
user's settings. The GitHub repo is `gokturkgocen/EqLume`.

## Build / run

```bash
./build.sh            # builds build/Eqlume.app (signs with Apple Development if present, else ad-hoc)
./build.sh install    # also copies to /Applications and is the normal deploy step
```
- Plain `swiftc`, no Xcode project. All `Sources/*.swift` compiled together.
- Signs with a stable **Apple Development** identity if one exists (keeps TCC permissions
  across rebuilds), otherwise falls back to ad-hoc signing so anyone can build without an
  Apple Developer account (override via `SIGN_ID=... ./build.sh`). Requires **macOS 26.0+**
  (build target `arm64-apple-macos26.0`, `LSMinimumSystemVersion` 26.0), Apple Silicon (arm64).
  NB: the `@available(macOS 14.2, *)` annotations in source are stale minima; the real
  floor is 26.0 per the build target / Info.plist.
- Menu-bar only (`LSUIElement`). No dock icon.

## What it does

- Captures system audio via **Core Audio process tap** (`muteBehavior = .muted`) + a private
  **aggregate device**, runs it through **AVAudioUnitEQ**, plays back through the real output
  device. No virtual driver / kernel extension (works with just a free Apple ID).
- **Which outputs get EQ'd — three tiers** (`AudioEngine.shouldProcessForCurrentDevice`):
  1. **Built-in 3.5mm jack** (`hdpn` data source) → always on, `OutputProfile.chuII`
     (the Chu II → Harman in-ear correction). This is the measured combo.
  2. **Built-in speakers** (`ispk`) → never processed; Apple's own DSP is left alone.
  3. **Any other output** (HDMI/DisplayPort monitor speakers, USB DAC, Bluetooth …) →
     **opt-in per device**, keyed by Core Audio device UID in `DeviceEQPolicy`
     (UserDefaults `Eqlume.enabledOutputDeviceUIDs`, stable across reconnects). Once
     enabled it runs `OutputProfile.desktopSpeakers`.
- **Baseline is per-device, and that is the whole point** (`OutputProfile` in
  `OutputProfile.swift`): music presets store ONLY their genre delta and set
  `usesDeviceBaseline = true`; `EQPreset.resolved(baseline:)` folds in the profile's baseline
  before the preset reaches the EQ node. `.chuII` → `chuIIBaseline`;
  `.desktopSpeakers` → `desktopSpeakerBaseline` (small 2.1 desk set: trim sub-45 Hz the sub
  can't play, tame the 80 Hz one-note hump and the 200 Hz cabinet/desk boxiness, small 500 Hz
  body fill, +2.5 dB at 3 kHz for the off-axis vocal recession, +2 dB air shelf — class-typical
  faults, not a measurement of one model; tune by ear from there). Never apply the Chu II
  in-ear correction to a speaker — an IEC-711 coupler correction does not transfer to a
  transducer radiating into a room. `flat` and `voice` are standalone
  (`usesDeviceBaseline = false`) and behave identically everywhere.
  Caveat to fix if it ever matters: the opt-in list is one flat set, so ANY opted-in
  non-jack device gets the speaker baseline — a USB DAC + headphones would get the wrong
  curve. Add a per-device profile picker at that point, not before.
  `AudioEngine.resolvedPreset` is what the EQ and the drawn curve must both use; the curve
  cache key includes the profile (`StatusBarController.curveKey`) because one preset name
  resolves to different curves on different devices.
- **Muted-tap teardown INVARIANT (do not break):** the tap is a *global* `muteBehavior = .muted`
  tap — while it exists it silences the whole system except EqLume. So teardown must be bulletproof:
  `teardownAudioResources()` is idempotent and NEVER guarded by `isRunning`; `startCore()` is
  exception-safe (a `defer` tears everything down on any partial-start throw); `stopCore()` always
  tears down (no `guard isRunning` early return). Past bug: a start that failed mid-way during a
  device hot-plug left an **orphaned muted tap** (`isRunning=false` but tap alive → every later
  `stopCore` no-op'd) → the whole Mac stayed muted until EqLume quit. Also: on Apple Silicon the
  built-in speakers and 3.5mm jack share ONE device ID, so a headphone unplug flips
  `kAudioDevicePropertyDataSource` (ispk↔hdpn) WITHOUT a default-device change —
  `AudioEngine.updateDataSourceListener` watches that so `reconcile()` runs on plug/unplug too.

## EQ presets (`EQPreset.swift`)

- **Chu II baseline** (every music preset): measurement-derived correction → Harman in-ear
  2019v2. 7 filters, the CONSENSUS of 3 independent AutoEQ fits (HypetheSonics/Kazi/Super Review,
  all 711/GRAS-RA0045 + Harman IE 2019v2). This is the important part. Replaced an earlier hand-set
  baseline that mixed a 5128(4620) measurement with the GRAS-Harman target (incompatible) — it had
  no ~6 kHz presence lift and *boosted* the 10 kHz shelf when the Chu 2 actually needs it CUT
  (excess upper treble / ~14 kHz overshoot per ASR). A PEQ is only valid for the coupler+target it
  was fit on — keep measurement and target on the same rig. `maxBands=12` (7 baseline + up to 3 delta).
- Per-genre presets = baseline + small genre delta (hip-hop/trap/edm/.../voice). Deltas are
  engineering judgment, not measured — kept small (≤±4 dB). Voice preset is separate (not Harman).
- `globalGain = preampOffsetDB` (negative, prevents clipping). No makeup gain (user prefers
  clean dynamics over loudness; volume drop is expected, compensate at system volume).

## Auto preset selection (`AutoPresetSelector.swift`)

Per track, resolves a preset in this order:
0. **Pinned track** (`PinnedPresets`, `Eqlume.pinnedPresets`) — an (artist, title) → preset
   name map the user sets from the settings panel. It outranks EVERYTHING below, including a
   genre hint the player supplied, and skips the whole chain. Detection is a guess by
   construction, so for the few records played on repeat this is where the answer gets stated
   once instead of being re-decided every play. Key is the lowercased `artist||title` the
   player reports, so a different upload of the same song is a different pin. The stored value
   is `EQPreset.name` (the stable key, not `displayName`), and a name that no longer exists
   resolves to nil rather than crashing. Tag marker `★` → source "sabit / pinned".
1. **Pre-fetch cache** — Spotify/YT Music queue lookahead resolved the next track already → instant.
2. **Classical work titles** (`looksLikeClassicalWork`) — offline, before any lookup, because on a
   classical upload the artist field holds a performer no catalog has heard of while the title
   states the piece exactly. Qualifies on an opus/thematic-catalogue number (`Op. 9`, `BWV 846`,
   `K. 331` — single-letter catalogues require their period, a bare "d 2" is anything else), or on
   a classical form word TOGETHER WITH a movement number or a stated tonality. The tonality alone
   is not enough: "In A Major Way" is a soul album. Tag marker `♯` → source "eser adı / work title".
3. **Catalog** (`resolveGenre`) — best source first:
   - **MusicBrainz album votes** (`albumGenres`, tried first): the release group's own genre votes.
     Artist votes describe a career, which is wrong whenever one record departs from it — Tame
     Impala's artist votes are psychedelic rock 13 / alternative rock 5 / indie rock 3, so every
     track resolved to rock, but "Dracula" is on *Deadbeat*, whose album votes are dance-pop 3 plus
     house / tech house / techno / electronic → EDM. Two requests (recording search →
     release-group detail), cached per artist+title. Only a **plain studio album** counts:
     primary-type `Album` with NO secondary type, since "Dracula" also sits on "Now That's What I
     Call Music! 123", "Bravo Hits 132", remix singles and DJ-mixes, whose votes describe the
     package. `tags` are NOT used as a fallback here the way they are for artists — release-group
     tags are full of non-genres ("plattentests.de", "offizielle charts", "5+ wochen").
     Album coverage is thinner than artist coverage (Currents has no album votes at all), so this
     is a preference, not a replacement.
   - **MusicBrainz artist votes** (`artistGenres`): community genre votes WITH counts,
     count-weighted into a family via `mapWeightedGenresToPreset` + `genreKeywordRules`. Free,
     no API key (descriptive User-Agent + ≤1 req/s throttle), cached per artist. Accurate at the
     artist level where iTunes mislabels (Buckethead→"Electronic", Dire Straits→"Pop" are both
     fixed → metal / rock). Detection tag carries a `♪` marker (shown as source "MusicBrainz").
     The displayed genre name is the strongest vote INSIDE the winning family, not the strongest
     vote overall — otherwise the label contradicts the preset beside it (Deadbeat leads with
     `dance-pop` while its house/techno votes add up to EDM).
   - **iTunes** Search API genre (fallback), WITH `artistNamesRoughlyMatch` verification to reject
     confident wrong matches. Detection tag has no marker → source "katalog".
   - **NOT Spotify**: Spotify removed `genres`/followers/popularity from its Web API in 2024
     (`GET /v1/artists/{id}` returns only name/images/uri — verified live), so it's useless for
     genre. SpotifyAPI is kept only for now-playing + queue pre-fetch.
   On miss, both sources are retried once by splitting an `"Artist - Title"` embedded in the title
   (`splitArtistTitle`) — YouTube channels often put the uploader in the artist slot ("NEA ZIXNH")
   with the real artist in the title ("Gary Moore - Parisienne Walkways"); verified against the
   parsed artist. The popover shows the resolved SOURCE next to the genre dot
   (`EQViewModel.deriveSource`: MusicBrainz / katalog / analiz / ön-yükleme).
   **Three compounding faults once made `KIVIRCIK ALİ-GÜL TÜKENDİ` come out as Vokal/Diyalog**;
   all three are fixed and each is a trap worth remembering. (a) `splitArtistTitle` matched only
   *spaced* separators (`" - "`), so a bare dash left the channel name in the artist slot and the
   real artist was never looked up. It now also splits on a bare `-`/`–`/`—`, guarded so hyphenated
   names survive: both sides ≥3 chars AND at least one side multi-word (verified: Jay-Z, T-Pain,
   Blink-182, AC-DC do not split; "Sezen Aksu-Firuze" does). (b) iTunes labels Turkish folk simply
   **`Halk`**, so keyword rules must match bare `halk` / `türkü` / `sanat müziği`, not only
   `"türk halk"`. (c) `GenreLookupService` asked for `limit=1`, and a cover/feat. upload can
   outrank the original ("Kenan Ayık – Gül Tükendi (feat. Kıvırcık Ali)" → Hip-Hop/Rap); the
   artist check then rejected it and the whole lookup failed. It now fetches 5 and picks the first
   result whose artist actually matches (`artistNamesRoughlyMatch`), falling back to the top hit.
   **A second three-fault pile-up made a Chopin nocturne come out as METAL** — same shape, all
   three fixed, and the middle one is the reusable lesson. (a) The bare-dash split cut a musical
   key: "Chopin: Nocturne in E-flat Major, Op. 9 No. 2" split at `E-flat`, leaving the fragment
   "Chopin: Nocturne in E" to be looked up as an artist. It now refuses to split when the text just
   left of the dash is a single letter. (b) `artistNamesRoughlyMatch` accepted an UNANCHORED
   substring, so "Nocturne" — a Dallas metal/industrial band, third hit at score 76 — matched that
   fragment and beat the score-100 "Fryderyk Chopin" at the top of the same result set. Partial
   matches are now anchored AND directional: when the name we want is the shorter one it may be a
   prefix or a suffix of the candidate ("Chopin" in "Fryderyk Chopin"), but when the CANDIDATE is
   shorter it may only be a prefix, which is what admits "Sezen Aksu" for "Sezen Aksu feat. X"
   while rejecting a band name buried mid-string ("Helmer" in "Johannes Helmer Pedersen").
   (c) `searchArtistMBID` ended in `?? obj.artists.first`, so MusicBrainz could never answer "I
   don't know this artist" — any junk query was handed a stranger's genres at full confidence.
   That fallback is gone; unknown → `.noMatch`. Its one replacement is narrow: the TOP hit is
   accepted if its surname token matches, because MB indexes aliases and transliterations our
   normalizer cannot ("Frédéric Chopin" → "Fryderyk Chopin", where only "Chopin" survives).
4. **Audio-content classifier** (catalog miss) — deferred ~4.5s so the analysis ring fills with
   the current track, then Discogs-EffNet CoreML classifies from the audio itself. Catalog-independent.
5. Default → pop.

Now-playing sources: Spotify Web API (OAuth, has queue pre-fetch), YouTube Music (browser DOM
via AppleScript `execute javascript`, has queue pre-fetch), Apple Music / browsers (AppleScript).
Genre string → preset via `mapGenreToPreset`; Discogs styles → preset via `PresetFamily`.

**Transport controls** (`PlaybackController.swift`): the popover's ⏮ ⏯ ⏭ row routes to whatever
player is currently producing audio (resolved via `AudioSourceMonitor.currentSourceBundleID()` at
press time — no per-frame cost; silent no-op on an unsupported source). Per-source channel:
Spotify & Apple Music via AppleScript transport verbs (`previous track` / `playpause` / `next track`);
YouTube Music via JS click in `ytmusic-player-bar` (`YouTubeMusicService.sendControl`). Spotify uses
AppleScript **not** the Web API, so no extra OAuth scope / re-auth / Premium dependency. YT Music
control selectors were verified against the live DOM: current YTM uses `yt-icon-button` with
`#play-pause-button` / `.next-button` / `.previous-button` (old `tp-yt-paper-icon-button` kept as
fallback). `buildAppleScript(for:runningJS:)` is the shared injector for both read and control JS.

## Audio-content classifier (the big piece)

- **Model**: Discogs-EffNet (MTG-UPF), ONNX → CoreML. Input `[1,128,96]` mel, output 400 styles.
- **Mel** (`MelSpectrogram.swift`, vDSP): symmetric raw Hann → |rfft|² power → 96×257 unit_tri
  slaneyMel filterbank → log10(10000·x+1). **Verified bit-exact vs Essentia TensorflowInputMusiCNN**
  (max diff 0.0 in Python; Swift port self-tests to ~5e-6 on every load).
- **Pipeline & regeneration**: `ml-pipeline/README.md`. Bundled resources: `Resources/DiscogsEffNet.mlmodelc`,
  `mel_filterbank_96x257.f32`, `discogs_styles.txt`, `selftest_*.f32`.
- Audio path: `AudioEngine` IOProc downmixes tapped pre-EQ audio to mono into `AnalysisRingBuffer`
  (6s); `GenreClassifier` snapshots 4s, resamples to 16k (AVAudioConverter), runs inference off
  the main actor, aggregates 400 styles → `PresetFamily` by summed probability.
- **Discogs parents lie about one style** (`PresetFamily.fromDiscogsStyle`): `Modern Classical`
  is filed under the **Electronic** parent, so parent-genre mapping sent solo piano to EDM and
  lifted its bass. The `electronic` branch checks for a `classical` style first.
- **Voice is refused outright on music-only players** (`classify(allowVoice:)` +
  `AutoPresetSelector.musicOnlyBundles`). The guard below only rejects `.voice` when no single
  voice style is on top — which still let a string-heavy instrumental classical track come out
  as "Vokal / Diyalog", because the model put a `Non-Music---*` style on top and cleared the
  confidence bar. Sparse acoustic material genuinely reads as room tone to this model. So on
  Spotify, Apple Music and YT Music the classifier may not answer `.voice` at all and falls to
  the best music family; a browser tab keeps it, since a YouTube talk really can be speech.
  Nothing is lost: real speech on those services carries a catalog genre that resolves long
  before analysis runs. Note this can end in `Genre uncertain` + the neutral preset rather than
  a named genre — which is the honest outcome when the model is confused.
- **Voice grab-bag guard** (`GenreClassifier.classify`): 16 styles (13 `Non-Music---*` + 3
  `Children's---*`) all map to `.voice`. Summed-probability aggregation lets a sparse/slowed/
  downtempo *music* track leak small probability into many of them and win `.voice` even when no
  single spoken-word style is on top (e.g. slowed tracks like "Indica (Slowed)" → "Podcast").
  Fix: `.voice` may only win if the **single top style** is itself a voice style; otherwise fall
  back to the best non-voice (music) family. Genuine voice still reachable via comm-app bundle
  mapping and catalog genre hints. Don't widen `.voice` membership without re-checking this.
- **Local classifier confidence guard** (`!APP_STORE`): Discogs families are uneven in size, so
  the local build scores only each family's three strongest styles (weighted 1/0.5/0.25) instead
  of letting a large family accumulate hundreds of weak activations. `World` may not win merely
  by aggregation when its style is not individually on top, and low-confidence/low-margin results
  keep the neutral preset and display `Genre uncertain` / `Tür belirlenemedi`. Local catalog tags
  `arabesk`, `türk halk`, and `turkish folk` use the acoustic profile instead of the World bucket.
  These behavior changes are compiled out of the App Store flavor.
- **Apple `Worldwide` is not a genre** (`!APP_STORE`): iTunes files many Turkish releases under
  the storefront bucket `World`/`Worldwide` (verified with Azer Bülbül — “Alıştım”). The local
  catalog path rejects those generic values. A deliberately small, normalized list of canonical
  arabesk/fantezi artists resolves to the local-only `Arabesk / Fantezi` profile instead; unknown
  artists fall through to audio analysis rather than being mislabeled as World.
- **Title cleaning** (`cleanMusicTitle`, NowPlayingProviders.swift) strips tempo/edit variant tags
  (`slowed`, `sped up`, `nightcore`, `reverb`, `8d`, `bass boosted`, remaster/remix/live/…) inside
  ( )/[ ] before catalog lookup, so variant titles match the original recording's genre.

## Permissions the user must grant (one-time)

- **Audio Recording** (system audio capture) — first EQ enable.
- **Automation** → Spotify / Music / Chrome / Safari (for now-playing). Entitlement
  `com.apple.security.automation.apple-events` is set; menu has "Otomasyon izinlerini test et".
- **Chrome**: View → Developer → "Allow JavaScript from Apple Events" (for YT Music DOM read).
- **Spotify pre-fetch**: menu "Spotify ile Bağlan" → paste Client ID from developer.spotify.com
  dashboard (redirect URI `http://127.0.0.1:38123/cb`). Premium account. Tokens in Keychain.

## Localization (`Localization.swift`)

- **Runtime language switch, English default, Turkish selectable** (settings panel). `Loc.shared`
  is a `@MainActor ObservableObject` with `@Published lang` persisted in UserDefaults (`Eqlume.language`);
  views that observe it re-render on switch. `L` is a non-actor mirror (reads UserDefaults) for use
  off the main actor / in value types. Strings are inline: `loc.t("English", "Türkçe")` / `L.t(...)` —
  no `.strings` bundling, no key table, no missing-key bugs.
- **Preset names stay the stable key.** `EQPreset.name` is NEVER localized (it's load-bearing:
  Theme.family/accent match on it, UserDefaults persists it, chip active-state compares it). A separate
  `EQPreset.displayName` provides the localized label for display only. Do NOT rename `.name`.
- **Detection is structured, not parsed.** `AutoPresetSelector` exposes `lastArtist/lastTitle/
  lastSourceApp/lastSourceKind (DetectionSourceKind)/lastStatus (DetectionStatus)`; the view localizes
  from these. The old approach parsed Turkish substrings out of `lastDetection` (deriveSource/
  parseNowPlaying) — removed, because it broke the moment the strings were translated.

## UI (SwiftUI popover)

Menu-bar icon opens an `NSPopover` hosting `PopoverView` (SwiftUI via `NSHostingController`).
`StatusBarController` (NSObject) owns the model and pushes state into `EQViewModel` (ObservableObject).
- **Genre-dynamic accent**: the whole popover's accent color follows the active preset's family
  (`PresetFamily.accent` in `Theme.swift`) — rock=red, edm/techno=blue, country=brown, metal=chrome,
  etc. Animates on genre change.
- **EQ curve**: `FrequencyResponse.swift` computes the preset's combined RBJ-biquad magnitude response;
  drawn as a glowing accent curve with gradient fill in a `Canvas`.
- **Live spectrum analyzer**: `SpectrumAnalyzer.swift` (2048-pt vDSP FFT, 40 log bands, attack/decay)
  fed by a 30fps timer in the controller from `AudioEngine.snapshotAnalysisAudio`. Only animates while
  the popover is open AND EQ is running (headphone jack); decays to flat otherwise.
- Now-playing card, auto-preset toggle, preset chips, and an expandable settings panel
  (Spotify connect, automation/YT tests, login-at-start, quit) — NOT a SwiftUI `Menu` (renders
  unreliably in popovers); a `gearshape` toggle reveals an inline button panel.
- **"Why this genre?"** (`!APP_STORE`, settings panel → `showDetectionDetail`) shows
  `AutoPresetSelector.lastDetection`, which records which source answered and, for the audio
  classifier, its single most probable Discogs style with the confidence. That string was
  computed and written on every resolve but **read nowhere**, so a wrong genre could only be
  diagnosed by re-deriving the entire chain by hand against the live APIs. Legend is in the
  alert itself: `[name ♪]` MusicBrainz, `[name ♯]` classical work title, `[name ★]` pinned,
  bare `[name]` iTunes, `[style · NN%]` the classifier.
- **Pinning UI** is an `NSAlert` + `NSPopUpButton`, not a grid in the popover — the manual chip
  grid was removed for being cluttered, and pinning is a rare deliberate act that should not
  occupy screen space the rest of the time.
- **Only ONE preset chip is shown — `EQPreset.natural` (Chu II — Doğal/Harman).** The other 20
  presets still exist and are used by the auto engine, but the manual chip grid was intentionally
  removed (user found it cluttered/ugly): the active preset — including whatever auto picks per
  track — is already shown under the track title, so a full chip grid was redundant. History: a
  horizontal `ScrollView` of all chips didn't scroll inside `NSPopover` (swipe gesture not
  delivered) → tried a wrapping `FlowLayout` → user asked for just the single natural chip.
  Chip "active" highlight = `preset.name == vm.presetName && (!vm.autoOn || vm.autoHasSource)`
  (`vm.autoHasSource` set in `syncVM`): auto + no source → not highlighted; auto + source →
  follows auto's live pick; manual → the pinned choice.
- Build adds `-framework SwiftUI`. Offline UI verification: `ImageRenderer` collapses `ScrollView`
  content, so use real AppKit `NSHostingView.cacheDisplay` to snapshot the popover faithfully.

## Measurement-driven correction (`!APP_STORE`, in progress)

Why it exists: the genre path has a **hard ceiling** on this user's library, and the ceiling is
structural, not a bug. Discogs-EffNet's 400 styles contain **no** Turkish, Anatolian,
Azerbaijani, Caucasian or Middle-Eastern label (verified against `discogs_styles.txt`), so the
classifier cannot name this material even in principle; its closest answers are `Folk` →
`.acoustic` or `.world`, **both of which carry no delta at all**. Meanwhile the catalogs are
either empty (MusicBrainz has one vote on Neşet Ertaş and no entry at all for many artists) or
confidently wrong (Apple files the Azerbaijani xalq mahnısı "Evlərinin önü yonca" as **Pop**,
with the artist name matching exactly, so the verification that rejects bad hits waves it
through). A violinist with no catalog presence anywhere is unreachable by every naming path
the app has. So: stop naming the music, and correct the recording instead.

- `SpectrumMeasurement` — long-term average spectrum of the PRE-EQ tap, accumulated per artist
  across sessions into `~/Library/Application Support/Eqlume/spectrum-measurements.json`.
  8192-point FFT (5.9 Hz bins at 48 kHz) because at 2048 there are not enough bins inside one
  ERB down at 50 Hz for the low end to be measurable. Sampled 4 s every 5 s, ~46 frames per
  snapshot. A sample-rate change **resets** it: bins are only comparable on one frequency axis.
  Only accumulates while `audio.isRunning`, i.e. headphones in the jack.
- `AdaptiveCorrection` — turns that spectrum into at most 3 peaking bands. **No external
  reference**, and that is the whole point: every documented failure mode of automatic spectral
  matching (arbitrary reference choice, loudness dependence, heavy-handedness, song-specific
  nonsense) comes from having one. Here the reference is the recording's own spectrum smoothed
  over 3× the ear's ERB, and the anomaly is `ERB-smoothed − 3×ERB-smoothed`. Subtracting a
  smoothed copy of a curve from itself cancels any common offset, so playback level provably
  cannot influence the result (there is a test for this).

  Four things were learned the hard way and each is now a named guard:
  1. **One scale is not enough.** With the reference smoothed at exactly one ERB, a resonance
     about one ERB wide cancels most of its own detection — a 7 dB synthetic resonance showed
     up as 1.15 dB. Hence 1 ERB vs 3 ERB.
  2. **Nearest-bin log resampling makes a staircase.** At 48 Hz several 1/24-octave cells fall
     inside one FFT bin; every step of that staircase is curvature, and a band-pass operator
     reports curvature as resonance. It invented filters at 48 and 78 Hz on a spectrum with
     none. Cells with no bin of their own are interpolated.
  3. **Zeroing the anomaly outside the band manufactures an edge.** The first surviving point
     then reads as a peak against that step — a −3 dB filter at exactly the 100 Hz boundary.
     The band restriction applies to candidate SELECTION only; the curve stays intact.
  4. **Curvature in the tilt is not a resonance.** The knee where a recording's bass rolloff
     begins produces a genuine broad lobe. It is rejected by width: an anomaly wider than 60 %
     of the reference window is part of the timbre that window defines.

  Bounds, all deliberate: cuts to −3 dB but boosts only to +1.5 (a notch does not ring, and
  this app corrects by cutting); 0.2–1.5 octave bandwidth; ≥0.5 octave between filters; gain
  traded away as a filter narrows (AutoEq's high-Q-high-gain penalty); detection band
  100 Hz–10 kHz (below ~100 Hz the ERB is most of an octave, so resonance and timbre stop
  being separable in principle); ≥2000 frames and ≥3 distinct titles before proposing
  anything (a single voice's LTAS stabilises in 25–30 s, music is far less stationary).
  Every proposal is verified against the biquad magnitude it will actually realise
  (`FrequencyResponse`) and rejected if it does not reduce the anomaly.

- **Deliberately NOT wired to the audio path yet.** The algorithm is validated against
  synthetic spectra with known injected resonances (20 assertions: finds a 0.15-octave
  resonance and a hiss shelf, ignores a 2-octave hump, a pure tilt and a steep rolloff, is
  level-invariant, respects every bound). It has never been run on a real measurement, because
  there was no data yet. Read the JSON first, review the proposals, then wire application.

## Distribution — Mac App Store

- **Live on the Mac App Store as "EqLume" 1.0, free, since 2026-07-29.** Verified via
  `https://itunes.apple.com/lookup?id=6793070613`. Product page: `apps.apple.com/app/id6793070613`.
  The store build is the `APP_STORE` flavor of build 4 (`build/Eqlume-1.0-build-4.pkg`, 2026-07-28).
- **Two flavors, one source tree,** split by the `APP_STORE` compile flag (`#if !APP_STORE`).
  The store build **omits** (i) the bundled Discogs-EffNet model — it is CC BY-NC-SA, i.e.
  non-commercial, so shipping it in a store binary is the wrong license posture, and (ii) the
  Spotify OAuth path, so no user-supplied Client ID / loopback listener is needed. Local/GitHub
  builds keep both. `scripts/preflight-appstore.sh` asserts this by inspecting the built binary
  (no bundled `.mlmodelc`, and no `38123` / `api.spotify.com` strings).
- **Rejection lesson — Guideline 2.4.5(i), entitlements minimalism.** Build 3 was rejected because
  `Eqlume.appstore.entitlements` carried `com.apple.security.network.server` (and a
  `keychain-access-groups` entry) that the store flavor does not use — the loopback OAuth listener
  and Keychain token storage only exist in the non-store build. Apple reads the *declared*
  entitlements, not the code paths. Both were removed; the store entitlements are now app-sandbox,
  `network.client`, `device.audio-input`, `automation.apple-events` (+ its temporary exception).
  `build.sh` and `scripts/preflight-appstore.sh` both re-assert the forbidden ones are absent and
  the required ones present, via `codesign -d --entitlements`, so this cannot regress silently.
- `scripts/package-appstore.sh` reads `CFBundleShortVersionString` / `CFBundleVersion` out of
  `Info.plist` for the `.pkg` name — do not hardcode the build number there again.
- **Unreleased since 1.0** (in git, not in the store): the `EqLume` display-name rename, the
  App Store badge/README work, and the Turkish-folk classification fix. A store submission would
  need `CFBundleVersion` bumped past 4.

## Discoverability / awesome-list submissions

Marketing state, so it isn't re-litigated. Copy for every remaining channel is written and lives
in the launch kit (Show HN, r/macapps, r/headphones, AlternativeTo, Product Hunt) — the user posts
those himself; AlternativeTo blocks brand-new accounts for 7 days.

- `serhii-londar/open-source-mac-os-apps` **#1243 — open**. No PR template in that repo. A
  permanently "pending" commit status there is normal, not a failing check.
- `jaywcjlove/awesome-mac` **#2500 — open**, FOSSA license check passed. No PR template either.
- `iCHAIT/awesome-macOS` **#975 — closed**, replaced by **#993 (open)**. **The lesson:** that repo
  has a mandatory PR template whose footer says a PR that replaces it wholesale "will be closed
  without discussion", and its guidelines repeat it. #975 replaced the template with prose, so
  maintainer `herrbischoff` closed it in a 5-PR sweep with no comment (#977/#975/#974/#971/#969) —
  nothing was wrong with the diff. #993 re-submits the identical one-line entry with all seven
  template items filled. Two further rules of that repo worth knowing: it rejects Electron apps,
  and it rejects "AI prompt wrappers", while explicitly allowing *local, specialised ML models as
  one step of a larger process* — which is exactly what the Discogs-EffNet classifier is, and #993
  says so. Entry format follows the `Pasteboard Viewer` precedent: primary link → App Store, OSS
  badge → GitHub repo, plus the Freeware badge, description ending in a period, placed
  alphabetically between BackgroundMusic and Fader.
- README carries the App Store badge, a demo GIF, an architecture diagram and a
  "How it compares" table (vs eqMac / SoundSource / Boom 3D); `assets/social-preview.png` is a
  1280×640 card meant for GitHub → Settings → Social preview.

## Status

Functionally complete incl. genre-themed SwiftUI UI with live spectrum + EQ curve. All components
validated. Shipping on the Mac App Store (above). Per-device opt-in shipped (see "Which outputs get
EQ'd"): the 3.5mm jack always gets the Chu II correction, built-in speakers are never touched, and
any other output can be opted in to `desktopSpeakerBaseline` — a class-typical 2.1-desk-speaker
correction, **not** a measurement of the user's Logitech set, so it is meant to be trimmed by ear
(bass thin → 80 Hz toward −1; treble harsh → 3 kHz toward +1.5). That ear-tuning pass has not been
done yet.
Open future ideas (not started): album-art in now-playing card, user master bass/mid/treble trim,
a genuinely measured baseline for a specific speaker set, per-device profile choice (the opt-in
list is currently one flat set — see the caveat under "Which outputs get EQ'd").
