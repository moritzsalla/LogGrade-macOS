# Apply the tone curve to luma only

A per-channel contrast curve crushes a saturated colour's two low channels harder than its high
one, so saturated things get more saturated — the traffic signage went neon, visibly, before it
was measured. That looked like an unavoidable trade (more contrast buys brick separation, costs
colorimetric accuracy) until the curve was applied to the luma plane with the original chroma
merged back. Same tone, blue back on spec, red no longer glowing.

The per-channel and luma-only comparison table is in `docs/PIPELINE.md` under "The fix: apply the
tone curve to LUMA ONLY", which is where the measurements for this decision live.

## Consequences

- Preserving chroma preserves it for everything, wanted or not: the brick gains no saturation
  either. **Do not try to win that back with a uniform saturation boost** — tested, and it goes
  straight back to neon, because a uniform multiplier amplifies whatever is already most
  saturated, which is the signage.
- Darkening alone still raises apparent saturation, because luma-only shaping lowers Y and leaves
  CbCr untouched. Gamma is the dial that trades "darker" against "less neon".
- The Grade Bench applies its preview curve the same way. If one changes, the other must, or the
  preview stops predicting the render.

## What the graph actually does, measured later

`lut1d` cannot process a YUV plane. ffmpeg auto-inserts a scaler — it says so itself, `picking
gbrp10le out of 26 ref:yuv444p10le` — so the curve is applied to R, G and B INDEPENDENTLY, and
`mergeplanes` then takes the luma of that per-channel-curved image and merges the original chroma
back.

So half of this decision holds exactly and half does not. The chroma really is untouched, which is
what stops saturated signage going neon, and that was the measured problem. But the luma that
lands is the luma of a per-channel curve rather than the curved luma, and those are different
transforms: for one saturated patch the plane came out at 243 of 1023 where curving the luma
predicts 141.5 and curving each channel predicts 241.4.

The image is not wrong — the grade was tuned by eye on exactly this behaviour, and it is what
shipped. The DESCRIPTION was wrong, and anything modelling this stage from the description rather
than from the behaviour is wrong with it: that is the whole of the divergence the Bench showed for
months. See tests/grade-parity.py, which now measures the shipped look at about 1.6 code values
rather than 29.

Changing the filter graph to make the description literally true would change every rendered image,
so it is not done here. If it is ever wanted, it is a new decision with a new record.
