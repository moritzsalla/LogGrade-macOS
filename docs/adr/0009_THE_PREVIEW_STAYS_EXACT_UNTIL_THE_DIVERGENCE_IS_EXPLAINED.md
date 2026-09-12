# The preview stays exact; no GPU tier until the divergence is explained

The plan for this app had two preview tiers: an approximate one on the GPU that follows a slider
continuously, and an exact one — a frame through the real chain — on release. Only the exact tier
is built. The GPU tier is not deferred for time; it is refused on evidence.

## What was measured

`tests/grade-parity.py` compares the browser bench's per-pixel grade against ffmpeg's own output
over a probe image. On the shipped look the worst divergence is about 29 code values, and on the
tone case alone about 36. Seven models were fitted to explain it and every one was rejected:

- the space, and the point at which channels are clipped. Adding one luma delta to R, G and B is
  algebraically identical to curving Y while holding Cb and Cr, so rewriting the bench into luma
  and chroma changed nothing at all.
- the filter order. Moving saturation ahead of warmth improves the trims case and leaves the tone
  case untouched.
- the conversion matrix. 709 fits better than 601 and than 2020.
- the range. Full fits better than limited, which corroborates the ramp measurement independently.
- which plane is curved. Curving chroma instead of luma is three times worse.
- any linear luma at all. The shift ffmpeg applies is uniform across channels to within 0.004 code
  values, but a least-squares fit over 357 unclipped patches lands back on 709's own weights and
  still leaves 32 code values of residual.
- a linear-light luma. It fits the single worst patch almost exactly and is worse everywhere else.

The effect is real, deterministic and reproducible on one pixel: render a flat patch of
242.9/55.4/64.8 through `grade_chain` with the shipped curve and ffmpeg shifts every channel by
−31.90, where the curve at that colour's 709 luma of 95.9 says −60.67. A near-neutral patch in the
same render agrees to 0.01, and the error grows with saturation.

## The decision

A GPU preview is a second implementation of the image. This repo permits exactly one of those, and
only when a test can hold it to the first — that is what ADR 0008 says and what the conformance
test enforces for the render. The gate for a preview is the parity golden, and the golden currently
measures a divergence nobody can explain. Building against it would mean shipping an interface
whose numbers are wrong in a way that is known, unquantified in cause, and largest exactly where
this footage lives: saturated signage, which is what the whole calibration is built around.

So the preview is the render. One frame, through the real chain, on release.

## Consequences

- **Adjusting a control costs a second or two rather than being instant.** Accepted. A preview that
  is fast and wrong is worse than one that is slow and true, and this project's entire history is
  silent wrongness — a filter negotiating 8-bit, tags never written, a curve turning signage neon.
- **The scopes are better for it.** They read the rendered frame, so they measure what was produced
  rather than what an app predicts would be produced.
- **What would reopen this:** explaining the divergence. The next step is reading ffmpeg's own
  handling of a 10-bit plane between `format`, `lut1d` and `mergeplanes`, not fitting an eighth
  model. With a cause in hand, the GPU tier becomes ordinary work with the golden as its gate.
- **The CPU reference twin is not built either**, for the same reason: it would be a reference to a
  model that has not been established.

## The cause was found, and this decision now rests on something smaller

Measuring the intermediate planes rather than fitting another model to the output answered it in
three commands. `lut1d` cannot process a YUV plane, so ffmpeg converts to `gbrp10le` and the tone
curve is applied per RGB channel; `mergeplanes` then takes the luma of that and merges the original
chroma. The Bench modelled the description instead of the behaviour. Modelling the behaviour, plus
clamping in the plane rather than in RGB and using colorbalance's measured midtone window, moves
the shipped look from 29 code values to **1.6** — and the tone case alone to 1.5.

So the reason given above is spent. What is left is narrower and worth stating exactly:

- The **shipped grade** is modelled to about 1.6 code values, which is within the conversion floor
  of a round trip plus rounding.
- Cases at the **extremes of warmth**, ±0.12 against the shipped 0.005, still diverge by about 20.
  colorbalance's window was measured at one amount on a grey ramp, and whether it weights by luma
  or by each channel's own level is not yet established.

That is now an ordinary piece of work with a harness that can hold it, rather than an unexplained
gap. A GPU preview is buildable when someone wants one; this record no longer refuses it, it only
says the trims are not finished. The exact preview stays the default regardless, because it costs a
second and cannot be wrong.
