# Grade by tone; do no colour correction

The footage reads flat, and the obvious reading of flat is that the colour is wrong. It isn't.
Calibrated against three legally standardised colours physically in frame (RAL 1021 plate yellow,
RAL 3020 traffic red, RAL 5017 traffic blue), the image is already accurate with nothing applied.
Every colour correction tried moved one of those references further off spec, including the
saturation boost that sent the red neon and the "restoring golden-hour warmth" that pushed the
blue away from its spec. The flatness is tone: too bright, with nothing reaching black. So the
grade is a tone stage, and the pipeline carries no colour correction at all.

The readings are in `docs/PIPELINE.md` under "Calibrating against standardised colours in frame",
which is where the measurements for this decision live. They are deliberately not copied here.

## Consequences

- Saturation and warmth do appear in the shipped grade (1.27 and 0.005), and they are a
  **creative departure**, not a correction — they put the blue at B/G 2.39 on purpose. A reading
  that looks "wrong" is not a reason to change them. This is the one number kept here, because it
  is the size of the departure rather than evidence for the decision.
- This only holds because the white balance was locked at capture. Auto WB would drift per clip
  and each clip would need its own correction, which is exactly the thing this decision rules out.
- It is reversible per clip if a future shoot's references measure off spec — the decision is
  "measure first", and this shoot's measurement said no correction was needed.
