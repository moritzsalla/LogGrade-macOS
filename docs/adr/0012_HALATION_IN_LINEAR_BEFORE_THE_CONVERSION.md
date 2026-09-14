# Halation is added in linear light, before the conversion, and only past edges

The look read as graded video rather than film, and the most recognisable film artefact was absent:
halation, the warm glow bright things grow into the dark around them where light reflects off the
film base and exposes the red layer a second time. A cube cannot produce it, because it is spatial.
It is now a stage of its own, between the input correction and Apple's conversion.

## Considered options

- **After the conversion, on the display-referred picture.** Cheapest, and tried first as a quick
  test. It is the wrong place to add light: the conversion has already landed every highlight on
  the same ceiling, so a sky and a white car contribute the same glow however much brighter one
  was. Apple Log still holds that difference — about twelve stops — so the glow is computed there.
- **Blur the highlights and add all of it.** Rejected by eye on IMG_0607: an overcast sky is one
  large bright area, it glowed onto itself, and the whole sky turned pink. A uniform field's own
  halation is part of a film stock's measured response. What reads as halation is the part that
  spills past an edge.
- **Edge-only: add `blur(highlight) − highlight`, clamped at zero.** Shipped. It leaves a bright
  field alone and puts the glow where the eye expects it, on the dark side of the car roof and the
  building edge.

## How, in ffmpeg

`halation_prefix` in `scripts/lib.sh` builds it, from four 1D cubes `scripts/make-halation-luts.py`
generates. Three traps shaped it, each silent, each measured; the measurements live beside the
code that avoids them and in `docs/PIPELINE.md`:

- `lut1d` ignores a negative `DOMAIN_MIN`. Apple Log decodes to −0.056 at black, so the linear
  values carry an offset that keeps them positive.
- `blend` addition, `avgblur` and `boxblur` clamp float at 1.0. `mix` and `gblur` do not.
- `gblur`'s default single step is not a Gaussian; three steps are within 15% of one.

The glow itself is computed at quarter resolution. At full resolution the stage nearly tripled the
conversion's CPU time for a difference of 0.05 code values on average against the quarter-resolution
glow.

## Consequences

- **A strength of 0 removes the stage from the graph.** Even idle, the float round trip moves the
  picture by 0.23 code values on average against the 10-bit path, so "neutral" has to mean
  "absent". The measurement is the reason. That it also left the default render byte-identical to
  the precursor was, after ADR 0014, a side effect.
- **The preview is a second implementation, and half of it is held exactly.** `LiveHalation`'s
  arithmetic is compared with the generator's cubes entry for entry. Its blur cannot be — the
  render and the preview blur different frames with different kernels — so it is held to the render
  by `LiveChainTests`: mean 1.52, 99.9th percentile 19 at strength 0.8, against 46 at the
  percentile when the live glow is removed.
- **The staged path refuses a look with halation.** A baseline has already been converted. The
  same refusal now covers the input correction, which that path had been silently leaving out of
  every master since the correction existed.
- **Threshold is in scene light, radius in frame height.** 1.0 is diffuse white; a radius of 0.006
  is 23 pixels on this camera's 3840-line frame, and the same part of the picture at any resolution.
