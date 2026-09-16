# Backlog

Open work only. Finished work lives in git.

## What the app is

Footage in, pick a look, and it looks finished. The better it does by itself, the less anyone
touches. Two users: Moritz and a non-technical photographer. Adjustment is optional and out of the
way for whoever doesn't want it. Judge every entry by that.

**Looks.** Five fixed presets, each owning its grain (not editable, only switchable):

| Look | Grain | Judged against |
|---|---|---|
| Neutral: our own rendering, finished, nothing clipped for effect | off | eye |
| **Portra 160**, the one that matters most | on | the partner's analog scans |
| Portra 800 | coarse | public references, then eye |
| IMAX | fine | public references, then eye |
| Super 8 | heavy | public references, then eye |

Sign-off is both users calling a look good enough. It stays improvable. Moritz called Portra 800,
IMAX and Super 8 good enough for now, not exceptional; the partner has not judged them.

**Right panel.** Look picker, one per batch. Adjust, per clip: Exposure, Warmth, Tint, Contrast,
Saturation, and the per-clip exposure match (on by default). Scopes (levels, parade, vectorscope)
and the curve, read-only. Sections with a bypass: Stabilisation (strength, off by default), Denoise
(strength, off by default), Grain (on/off; off for Neutral, on for film).

**Export.** A picker: Instagram Story, Instagram Post (no fields), Custom (resolution, aspect and
crop, frame rate, codec up to ProRes 422 HQ, quality, container, audio). SDR only. Framing defaults
to centre, dragged per clip; export warns about clips whose framing was never looked at.

**Tests** earn their place by speeding iteration: the silent-failure guards and the render golden
(a change detector, not an approved image) stay; parity against the precursor goes.

## Next, in order

1. **Portra 160 against the scans** (arriving). Tone, colour and grain side by side, then both users
   judge.
2. **Neutral on a sunny, contrasty scene.** `luts/rendering/neutral.cube` was judged on one overcast
   shoot and IMG_0609 only. The render golden is Neutral, so it moves with this.
3. **Delete the engine controls no look uses**, once the looks are signed off: wheels, hue curves,
   halation and tone internals, with their tests and the live preview's copies.

## Also open

- **Verify the universal app on the Apple silicon Mac.** Kind: Apple for LogGrade and ffmpeg; one
  render with stabilisation; how far it differs from this Mac's (arm64 ffmpeg is OSXExperts 9.0,
  x86 evermeet 9.0.1); jq 1.8.2 (minos 14) if that Mac runs macOS 13. `docs/UNIVERSAL_APP_PLAN.md`.
- **Export is slow on the Intel Mac.** Measure where the time goes first.
- **Judge sharpen and grain at other heights by eye**, now that Custom exports any size. Grain stays
  ~1 output px, 1.7× coarser relative to the picture at 960 than at 1920 (`docs/PIPELINE.md`).

## Not doing

- Trimming, cutting, a timeline.
- Local adjustments (a sky or a face held separately).
- A separate ambience recording.
- Importing LUTs; editable tone or hue curves.
- HDR delivery.
- Cameras other than iPhone Apple Log. Apple Log 2 maybe, much later.
- The filmic route: it lost on colour (`docs/PIPELINE.md`).
- A native render in AVFoundation (ADR 0008).
