# Keep Apple's CST rather than the from-scratch filmic route

The textbook-correct architecture is to decode Apple Log to scene-linear, apply a filmic tone
curve in linear where highlight rolloff and shadow density behave properly, and encode to Rec.709.
That route was built (`make-filmic-lut.py`) and it did produce a better tone response, using far
more of the range. It lost on colour and is not what ships.

## Considered options

- **1D LUT, log→linear only.** Impossible: Apple Log is in BT.2020 primaries and a 3×3 gamut
  matrix is not expressible as a per-channel curve. Badly under-saturated when measured, because
  BT.2020 numbers read as Rec.709 desaturate.
- **3D LUT with the gamut matrix at 65³.** Better, still short. Per-channel tone mapping
  desaturates by construction, so a global saturation multiplier was added to compensate — which
  overshot the standardised blue well past its spec.
- **Apple's CST, tone shaped afterwards in display space.** Blue near-exact, more brick
  separation. Shipped.

Every figure behind those three lines is in `docs/PIPELINE.md` under "Approach A" and
"Approach B", which is where the measurements for this decision live.

Apple's gamut handling is better colour science than anything hand-rolled here, and the
standardised references are what proved it rather than a preference.

## Consequences

Display-space shaping cannot recover highlight detail the CST has already compressed. It is
workable because the CST does not clip on this footage, so there is room to shape.
`scripts/make-filmic-lut.py` is kept: the architecture is right and may win with proper gamut
mapping. It is a dead end on record, not dead code to delete. The generated cubes under
`luts/filmic/` are gitignored — they are reproducible output, so a fresh clone has only
`SOURCE.txt` and regenerates from the script. The measurements that decided this live in this file,
not in those files.
