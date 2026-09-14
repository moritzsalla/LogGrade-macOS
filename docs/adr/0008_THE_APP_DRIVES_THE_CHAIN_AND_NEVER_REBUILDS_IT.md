# The app drives the shell chain and never rebuilds it

The interface this repo is for sets environment variables, spawns `scripts/grade.sh` and reads its
event stream. It does not construct a filter graph, and it does not reimplement a stage. The engine
stays the source of truth for the image.

## Considered options

**Rebuild the chain in Core Image and AVFoundation.** The textbook answer for a native Mac app, and
it is the wrong one here on three counts.

- Apple's own technote on colour in AVFoundation states that it colour-matches every pixel from the
  source colour space to the destination. With Apple Log in BT.2020 going to Rec.709, that is an
  invisible transform layered on top of the LUT — the *bleached* failure class arriving through the
  framework rather than through a tag. Suppressing it means controlling every buffer's attachments
  by hand, which trades a verification remux that already exists for a silent conversion that would
  have to be disproved.
- `h264_videotoolbox` has no constant-rate factor. The shipped encode is `libx264 -crf 18 -preset
  slow`, and grain survival through a platform re-encode was measured against it.
- The chain is not a list of filters, it is the residue of measured failures: a spline that
  overshoots, a filter that silently negotiates 8-bit, a flattening filter, an untagged branch that
  poisons a converter several filters upstream, grain that rings when it precedes the sharpener.
  None of that transfers to another framework. It would all have to be rediscovered.

**Drive the shell chain. Shipped.** The engine is already measured, already tested, and already
verified byte-identical to its precursor.

## Consequences

- **The preview's divergence is measured, and its cause is not yet known.** The browser bench sat
  about 36 code values from the renderer on the tone case, and `tests/grade-parity.py` records
  which six explanations have been ruled out: the space, the clipping point, the filter order, the
  conversion matrix, the range, and which plane is curved. What remains to test is ffmpeg clamping
  out-of-gamut colour in YUV rather than in RGB. A GPU preview should start from that rather than
  from the assumption that the bench's algorithm is nearly right.
  (Written while the bench existed. The cause was found — it modelled the chain's description
  rather than its behaviour — and the bench has since been deleted, ADR 0007. The per-pixel
  comparison runs against Swift's `LiveGrade` in `LiveGradeTests` now.)
- **A GPU preview is still possible and is a separate decision.** What is forbidden is a second
  implementation of the *render*. A preview that approximates it must be measured against it, and
  the tolerances are a decision of their own, to be recorded when that preview exists.
- **The enforcement is a test, not a convention.** `EndToEndTests` renders one clip through the
  engine from the shell and through the app, and asserts the outputs are identical. They must be:
  it is the same binary with the same arguments. Anything less than identity means the app
  started building its own graph, which is the one failure this whole arrangement exists to
  prevent. (This record first named `tests/conformance.sh`, which compares against the precursor
  instead. ADR 0014.)
- **The engine must be legible to a program.** That is what the event stream and the named refusal
  codes are for, and why stdout carries one format.
