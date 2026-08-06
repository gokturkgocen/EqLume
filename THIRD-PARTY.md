# THIRD-PARTY NOTICES

EqLume is distributed under the MIT License (see `LICENSE`), which covers **only the
original source code authored by Göktürk Göcen** (the `Sources/*.swift` files,
`build.sh`, the `ml-pipeline/*.py` scripts, and other first-party files in this
repository).

EqLume also **bundles and depends on third-party components** that are **not** covered
by that MIT License. Those components remain under their own licenses, and their terms
govern over the MIT License wherever they apply. This file documents each third-party
component, its authors, its license, and the obligations it imposes.

> **IMPORTANT — the distributed application is effectively NON-COMMERCIAL.**
> EqLume bundles the Discogs-EffNet machine-learning model, which is licensed under
> **Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
> (CC BY-NC-SA 4.0)**. Because a compiled derivative of that model
> (`Resources/DiscogsEffNet.mlmodelc`) is redistributed as part of the app binary, the
> **application as a whole may not be used or distributed for commercial purposes**, and
> any redistribution of the model (or the app containing it) must preserve attribution
> and be shared under the same CC BY-NC-SA 4.0 terms. The MIT License on the author's
> code does **not** grant you commercial rights over the bundled model. If you need a
> commercial-use build, you must remove the Discogs-EffNet model and any files derived
> from it, and replace the audio-content genre-classification feature.

---

## 1. Discogs-EffNet music-style classification model

**Component:** `Resources/DiscogsEffNet.mlmodelc` (compiled Core ML model, bundled and
redistributed in the app), together with its derived resources:
`Resources/discogs_styles.txt` (the 400-label style taxonomy), and — in the source
tree — `ml-pipeline/DiscogsEffNet.mlpackage`,
`ml-pipeline/discogs-effnet-bsdynamic-1.onnx`, and
`ml-pipeline/discogs-effnet-metadata.json`.

**Original model:** "Discogs-EffNet" / `EffnetDiscogs` (EfficientNet-B0), a music
style-classification and embedding model predicting the top-400 Discogs music styles.

**Authors / origin:** Music Technology Group, Universitat Pompeu Fabra (MTG-UPF),
Barcelona — Pablo Alonso-Jiménez, Xavier Serra, and Dmitry Bogdanov. Distributed as part
of the **Essentia** models collection.

**License:** **Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
(CC BY-NC-SA 4.0)** — https://creativecommons.org/licenses/by-nc-sa/4.0/

**Source / homepage:** https://essentia.upf.edu/models.html

**Redistribution note:** `Resources/DiscogsEffNet.mlmodelc` is a **compiled derivative**
of the original Essentia model. It was produced by converting the upstream ONNX model
(`discogs-effnet-bsdynamic-1.onnx`) to Core ML via the pipeline in `ml-pipeline/`.
As a derivative work of a CC BY-NC-SA 4.0 model, this compiled model — and any
application that bundles it — is itself licensed under **CC BY-NC-SA 4.0**: it may be
used and redistributed for **non-commercial purposes only**, **with attribution**, and
any distributed adaptation must be shared under the **same** license.

**Required attribution / citation (ISMIR 2022):**

```bibtex
@inproceedings{alonso2022music,
  title={Music Representation Learning Based on Editorial Metadata from Discogs},
  author={Alonso-Jim{\'e}nez, Pablo and Serra, Xavier and Bogdanov, Dmitry},
  booktitle={Conference of the International Society for Music Information Retrieval (ISMIR)},
  year={2022}
}
```

---

## 2. Essentia MusiCNN mel-spectrogram input recipe

**Component:** The mel-spectrogram feature-extraction recipe reproduced by
`Sources/MelSpectrogram.swift`, and the precomputed mel filterbank shipped as
`Resources/mel_filterbank_96x257.f32` (and, in the source tree,
`ml-pipeline/mel_filterbank_96x257.f32` / `.npy`, plus the self-test vectors
`selftest_input.f32` and `selftest_mel.f32`).

**Origin:** The input pipeline follows Essentia's `TensorflowInputMusiCNN` recipe — the
MusiCNN mel-spectrogram front-end that the Discogs-EffNet model expects (16 kHz mono →
frame 512 / hop 256 → Hann window → power spectrum → 96-band Slaney/`unit_tri` mel
filterbank → `log10(10000·x + 1)`). The Swift port was validated to be numerically
equivalent to Essentia's implementation.

**Authors / origin:** Music Technology Group, Universitat Pompeu Fabra (MTG-UPF), as
part of the **Essentia** open-source audio-analysis library
(https://essentia.upf.edu/). The MusiCNN front-end derives from the work of Jordi Pons
and Xavier Serra (MusiCNN).

**License / relationship:** The Essentia library is distributed under the
**GNU Affero General Public License v3 (AGPL-3.0)**. EqLume does **not** link against,
include, or redistribute Essentia or any Essentia source code — the Swift
implementation is an **independent, from-scratch reimplementation** of the documented
mel recipe (Accelerate/vDSP), written to match Essentia's numerical output. The mel
filterbank coefficients are a data artifact of that recipe. Essentia is used only
offline, in `ml-pipeline/` (validation scripts), to generate and verify these
artifacts; those scripts are dev-only and are not part of the shipped app.

**Homepage:** https://essentia.upf.edu/

---

## 3. Discogs style taxonomy (400 style labels)

**Component:** `Resources/discogs_styles.txt` — the ordered list of 400 music-style
labels in `Parent---Style` format (e.g. `Electronic---Deep House`), also embedded in the
model's output layer.

**Origin:** These labels are the **Discogs** community music-style taxonomy, as used to
train the Discogs-EffNet model. The label set is an integral part of the model's output
vocabulary and is redistributed here as part of the same CC BY-NC-SA 4.0 model derivative
described in section 1. "Discogs" is a service and trademark of Zink Media, LLC; the
taxonomy terms are used here only to name the model's output classes, and no affiliation
with or endorsement by Discogs is claimed.

---

## 4. Runtime web services (used at runtime, not redistributed)

The following services are queried over the network at runtime to resolve now-playing
metadata and per-artist/per-track genre. **No data or content from these services is
bundled in or redistributed with EqLume**; the app is only an API client. Each service is
governed by its own terms of use. Users deploying or forking EqLume are responsible for
complying with those terms and for supplying their own credentials where required.

- **MusicBrainz** — used via the MusicBrainz Web Service v2
  (`https://musicbrainz.org/ws/2`) to resolve an artist's community genre/tag votes.
  MusicBrainz **data** is released into the public domain / under permissive terms (core
  data is **CC0**; some supplementary data is **CC BY-NC-SA**). Use of the API requires a
  descriptive `User-Agent` header (EqLume sends one identifying the app and its repo) and
  roughly ≤ 1 request/second, per the
  [MusicBrainz API policy](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting).
  Anyone redistributing a fork should set a `User-Agent` identifying their own build.

- **Apple iTunes Search API** — used via `https://itunes.apple.com/search` to resolve a
  track's primary genre and to fetch album artwork. Subject to Apple's iTunes Search API
  terms and rate limits. Artwork and metadata are fetched on demand and displayed, not
  stored or redistributed. Apple, iTunes, and Apple Music are trademarks of Apple Inc.;
  no affiliation or endorsement is claimed.

- **Spotify Web API** — used for the currently-playing track and queue look-ahead only,
  via user-authorized OAuth (PKCE). Subject to the
  [Spotify Developer Terms](https://developer.spotify.com/terms). EqLume ships **no**
  Spotify client credentials; a user must supply their own Client ID. Spotify content and
  metadata are not redistributed. Spotify is a trademark of Spotify AB; no affiliation is
  claimed.

- **YouTube Music** — read via the browser's own open `music.youtube.com` tab (page DOM
  read through AppleScript/JavaScript) to obtain the currently-playing title/artist. No
  YouTube/Google API is called and no content is redistributed; EqLume only reads what is
  already displayed in the user's browser session. Subject to YouTube's and Google's Terms
  of Service. YouTube and YouTube Music are trademarks of Google LLC; no affiliation is
  claimed.

---

## 5. EQ baseline measurement data (Moondrop Chu II → Harman)

**Component:** The `chuIIBaseline` parametric-EQ filter set in `Sources/EQPreset.swift`
(the seven-band correction that every music preset builds on).

**Basis:** These filter values are **derived from third-party headphone measurements**,
not authored from scratch. They are the consensus of **three independent AutoEQ
parametric-EQ fits** for the Moondrop Chu II in-ear monitor toward the
**Harman in-ear 2019v2** target, all measured on IEC-711 / GRAS RA0045-class couplers,
from the community project:

- **AutoEq** by Jaakko Pasanen — https://github.com/jaakkopasanen/AutoEq
  (AutoEq is licensed **MIT**; the aggregated measurement results are published under the
  repository's terms.)

The three measurement contributors averaged for the EqLume baseline, as cited in
`Sources/EQPreset.swift`, are **HypetheSonics**, **Kazi**, and **Super Review**. EqLume's
baseline is an **average/adaptation** of their published parametric fits, not a verbatim
copy of any single result file. The **Harman target curve** referenced is research by
Harman International / Sean Olive et al.; only the correction toward it (not the target
curve values) is embedded here. The per-genre deltas layered on top of this baseline are
the EqLume author's own engineering judgment (first-party, MIT-licensed).

No measurement files, target-curve data files, or AutoEq source are redistributed —
only the derived filter coefficients embedded in `EQPreset.swift`. Product names
(Moondrop, Chu II) and target names (Harman) are used descriptively; no affiliation or
endorsement is claimed.

---

## Summary of obligations

| Component | License | Key obligation |
|---|---|---|
| Discogs-EffNet model + 400-label taxonomy | CC BY-NC-SA 4.0 | Attribution + **NonCommercial** + ShareAlike; **makes the whole app non-commercial** |
| Essentia MusiCNN mel recipe (reimplemented; filterbank data) | Recipe from AGPL-3.0 Essentia (no Essentia code shipped) | Credit MTG-UPF/Essentia; feature is bound to the NC model above |
| MusicBrainz (runtime API) | Data CC0 / partly CC BY-NC-SA | Descriptive `User-Agent` + ≤ ~1 req/s |
| Apple iTunes Search API (runtime) | Apple API terms | Comply with Apple terms/rate limits |
| Spotify Web API (runtime) | Spotify Developer terms | User supplies own credentials; comply with terms |
| YouTube Music (runtime DOM read) | Google/YouTube ToS | Comply with ToS; reads user's own session only |
| Chu II EQ baseline | Derived from AutoEq (MIT) measurements | Attribution to AutoEq + measurers (courtesy) |

---

*Files this repository intentionally does not publish (see `.gitignore`) — build
outputs, the Python virtualenv, and re-downloadable upstream model artifacts — are not
covered by these notices.*
