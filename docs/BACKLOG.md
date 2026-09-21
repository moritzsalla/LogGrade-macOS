# Backlog

Open work only. Finished work lives in git.

## What the app is

Footage in, pick a look, and it looks finished. The better it does by itself, the less anyone
touches. Two users: Moritz and a non-technical photographer. Adjustment is optional and out of the
way for whoever doesn't want it. Judge every entry by that.

**Looks.** Four fixed presets, each owning its grain (not editable, only switchable):

| Look | Grain | Judged against |
|---|---|---|
| Neutral: our own rendering, finished, nothing clipped for effect | off | eye |
| **Portra 160**, the one that matters most | on | the partner's analog scans |
| Portra 800 | coarse | derived from Portra 160 (a faster stock of the same look) |
| Super 8 | heavy | public references, then eye |

Sign-off is both users calling a look good enough. It stays improvable. Moritz called Portra 800,
Super 8 and the brighter Neutral good enough for now, not exceptional; the partner has not
judged them.

**Right panel.** Everything is per clip: clips are graded and exported one at a time. Look picker
(a clip given none follows the last look picked). Adjust: Exposure, Warmth, Tint, Contrast,
Saturation, exposure match (on by default). Scopes (levels, parade, vectorscope) and the curve,
read-only. Sections with a bypass: Stabilisation (strength, off by default), Denoise (strength, off
by default), Grain (on/off; off for Neutral, on for film).

**Export.** The selected clip, or all clips. A picker: Instagram Story, Instagram Post (no fields), Custom (resolution, aspect and
crop, frame rate, codec up to ProRes 422 HQ, quality, container, audio). SDR only. Framing defaults
to centre, dragged per clip; export warns about clips whose framing was never looked at.

**Tests** earn their place by speeding iteration: the silent-failure guards and the render golden
(a change detector, not an approved image) stay; parity against the precursor goes.

## Next, in order

1. **Native rendering, in stages** (the user: performance is "meagre everywhere"). Each stage is held
   to grade.sh output by tests, and grade.sh stays the fallback until a stage is at parity.
   Measured on the Intel Mac: an AVFoundation 10-bit 4K frame decodes in 0.10-0.19 s (ProRes),
   0.9 s (HEVC, first read); a Core Image 65³ cube at 2560x1440 takes 80 ms.
   - **Import:** one ffprobe per clip, clips probed in parallel.
   - **Preview:** done on the CPU (decode, meter and grade in-process, no engine render; ADR 0009).
     Left: the grade chain on the GPU, shared with Export.
   - **Export:** AVAssetReader, the same chain, the delivery stage, VideoToolbox H.264/HEVC through
     AVAssetWriter. ProRes, stabilisation and Super 8's gauge stay on grade.sh until at parity.
2. **Portra 160, the next calibration round.** Calibrated against the partner's scans (median 0.0073
   Oklab against their edits); still off, by the scorecard and by eye: the road and pavement too warm
   (dark neutrals had almost no samples), the clouds' blue shadows (sky colour per lightness band),
   saturated signs a touch dull, the palest brick ~19% short of the film's chroma. Method, findings
   and every round: the `look-match` skill. More scanned scenes with dark neutrals and blue would
   help more than more model. `calib.py` compares codes decoded with the inverse BT.709 OETF on
   both sides, but the edits are Adobe RGB and playback is gamma 1.961 (`cubefile.py`): decode
   each side by its own curve and primaries in the next round (numbers in `luts/film/CHANGELOG.txt`).
3. **Cross-check Super 8** against professional emulations (licence permitting, comparison only)
   and more reference stills per stock.
4. **Delete the engine controls no look uses**, once the looks are signed off: wheels, hue curves,
   halation and tone internals, with their tests and the live preview's copies.

## Also open

- **Verify the universal app on the Apple silicon Mac.** Kind: Apple for LogGrade and ffmpeg; one
  render with stabilisation; how far it differs from this Mac's (arm64 ffmpeg is OSXExperts 9.0,
  x86 evermeet 9.0.1); jq 1.8.2 (minos 14) if that Mac runs macOS 13. `docs/UNIVERSAL_APP_PLAN.md`.
  Also time one Instagram Story export there. On the Intel Mac it is ~4.2 s per footage second
  (IMG_0444 ProRes 19 s in 78 s, IMG_0308 HEVC 17.5 s in 75 s; stabilisation and denoise off),
  accepted for short clips. Only if that Mac is slow too, measure VideoToolbox H.264: it saves at
  most the encode share, and loses quality that Instagram's re-encode compounds.

## Not doing

- Trimming, cutting, a timeline.
- Local adjustments (a sky or a face held separately).
- A separate ambience recording.
- Importing LUTs; editable tone or hue curves.
- HDR delivery.
- Cameras other than iPhone Apple Log. Apple Log 2 maybe, much later.
- The filmic route: it lost on colour (`docs/PIPELINE.md`).
