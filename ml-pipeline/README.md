# EqLume ML pipeline — audio-content genre classifier

Offline pipeline that produces the catalog-independent genre classifier EqLume uses
when Spotify/iTunes lookup fails (obscure tracks not in any catalog).

## What it produces (already bundled into the app under `../Resources/`)

| File | Purpose |
|------|---------|
| `DiscogsEffNet.mlmodelc` | CoreML model: `[1,128,96]` mel → 400 Discogs styles |
| `mel_filterbank_96x257.f32` | Exact Essentia MusiCNN mel filterbank (96×257, row-major float32) |
| `discogs_styles.txt` | 400 style labels, `Parent---Style` format |
| `selftest_input.f32`, `selftest_mel.f32` | Swift mel self-test vectors |

## Model

[Discogs-EffNet](https://essentia.upf.edu/models.html) by MTG-UPF — EfficientNet-B0
trained on 2M+ recordings for 400 Discogs music styles. Catalog-independent: classifies
from audio content alone.

## The mel recipe (verified bit-exact vs Essentia, max diff 0.0)

```
16kHz mono → frame 512 / hop 256 → symmetric RAW Hann window
  → |rfft|² (POWER spectrum, 257 bins)
  → 96×257 unit_tri slaneyMel filterbank
  → log10(10000·x + 1)
  → [128, 96] patches
```

The Swift port (`Sources/MelSpectrogram.swift`) reproduces this with vDSP and is
validated against `selftest_mel.f32` on every classifier load (max diff ~5e-6).

## Regenerating (venv was deleted to save disk)

```bash
python3.11 -m venv venv && source venv/bin/activate
pip install coremltools onnx onnxruntime numpy torch onnx2torch essentia
# 1. download model
curl -sLO https://essentia.upf.edu/models/feature-extractors/discogs-effnet/discogs-effnet-bsdynamic-1.onnx
curl -sLo discogs-effnet-metadata.json https://essentia.upf.edu/models/feature-extractors/discogs-effnet/discogs-effnet-bsdynamic-1.json
python3 convert.py        # ONNX → CoreML (DiscogsEffNet.mlpackage)
python3 validate_mel.py   # verify mel recipe vs essentia (needs a test_16k.wav)
# then: xcrun coremlcompiler compile DiscogsEffNet.mlpackage ../Resources/
```

## Runtime flow (in the app)

`AutoPresetSelector` resolves a preset per track:
1. Catalog (iTunes) with artist-name verification → instant
2. On catalog miss → wait ~4.5s for clean current-track audio in the analysis ring →
   `GenreClassifier` (this model) → preset family
3. Default (pop) if all else fails
