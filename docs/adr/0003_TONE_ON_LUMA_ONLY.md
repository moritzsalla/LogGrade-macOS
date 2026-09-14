# Apply the tone curve to luma only

A per-channel contrast curve crushes a saturated colour's two low channels harder than its high one,
so saturated signage goes *neon*. Curving luma and merging the original chroma back gives the same
tone with colour untouched. Measured with one tone LUT: blue B/G went from 2.34 per-channel to 1.94
luma-only (spec 1.98), and red purity from 0.29 to 0.37.

## Consequences

- The brick gains no saturation either. Don't win it back with a uniform boost (docs/PIPELINE.md,
  "Tried and rejected").
- Darkening still raises apparent saturation; gamma trades "darker" against "less neon".

## What the graph actually does

`lut1d` cannot take a YUV plane. ffmpeg picks `gbrp10le` (`picking gbrp10le out of 26
ref:yuv444p10le`), so the curve is applied per RGB channel, and `mergeplanes` takes that image's luma
plus the original chroma. The chroma is untouched, so neon is still prevented. But the luma is the
luma of a per-channel curve: on one saturated patch it came out at 243 of 1023, where curving luma
predicts 141.5 and curving each channel predicts 241.4.

The grade was tuned on this behaviour and it ships. Anything modelling this stage must model the
behaviour, not the description. Changing the graph to match the description would change every
image, so that would be a new decision.
