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
