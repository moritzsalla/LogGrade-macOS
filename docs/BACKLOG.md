# Backlog

Everything raised and not finished. Ordered by what blocks what, not by size. Finished work is not
kept here: its reasoning lives in the ADR or commit that did it.

Most entries were inherited from the precursor and written about its one shoot; `PROVENANCE.md`
says what came across. The universal-app work has its own plan in `docs/UNIVERSAL_APP_PLAN.md`.

## Needs an eye

**Sign off the v4 look.** The proof carries four changes on top of the approved grade: black point
0.015 → 0.025 with gamma 2.09 → 2.02 (shadow detail), stabilisation, chroma-only denoise for the
sign shimmer, and clustered grain moved after the sharpener. The whole shoot has been rendered
against it, so judge it on those renders.

## Open work

**Judge the grain strength by eye.** `grain.strength` is 8, a starting suggestion. The
clustered-vs-per-pixel measurements are settled (`docs/PIPELINE.md`); the amplitude is the one
number that wants an eye. Override with `GRAIN_STRENGTH=n`.

**Sharpen and grain at other frame sizes.** The sharpener's radius follows output height and its
amount does not; the grain was sized at 1080. Both are assumptions, stated as such in
`delivery_image_chain`, the README and `USAGE.md`. Deliverables as data made other sizes reachable.
A MEASUREMENT task: render one clip at several heights and look.

**Re-measure the parity tolerance on purpose.** `grade_worst_by_case` was computed from the Bench's
JavaScript; with the Bench gone, `tests/grade-parity.py --regenerate` copies it forward and says so.
As a regression ceiling that is correct. Missing: a way to re-measure it when a change is meant to
move it.

**An editor for arbitrary deliverable shapes in the app.** The engine and project file carry any
shape; the app toggles `Deliverable.presets` and lists anything else read-only.

**Audio.** Measured clean — PCM stereo, unclipped, 24 dB crest, real L/R decorrelation (0.54), never
lossy. Available: a 60–80 Hz high-pass for the rumble that is currently the loudest thing in the
file, and a separate ambience recording (phone set down) for street detail handheld capture misses.

## Blocked

**Two-dimensional crop geometry — blocked on ADR 0005, not on size.** `crop_prefix` always takes the
full source width at x=0, because a window narrower than the source needs a deliverable taller than
the source, which it refuses. With portrait-only ingest there is no horizontal freedom, so a 2D
picker would be a control with nothing behind it. Reopen only if ingest accepts non-portrait
sources.

## Cleanups

**`02-grade.sh`'s header is stale in two places.** It uses "look" for both the Portra LUT and the
whole grade, and still says "the saturation and warmth below" when the values moved to `look.json`.

## Considered and declined

Kept here so they are not re-litigated from scratch.

- **A better Portra LUT.** Every freely reachable one is the same coarse 13³ G'MIC grid. The
  print-film emulation this once called out of reach was not: the same source has Kodak 2383 for
  Rec.709. It is the `print` stage; see `luts/print/SOURCE.txt`.
- **The scene-linear filmic route.** Architecturally correct, lost on colour. ADR 0002.
- **Collapsing the tone curve and trims into the shared cube** (the OpenColorIO shape). Flattening
  stages onto one grid cost 55 code values against 48 for sampling in sequence, because the film
  look's grid is only 13 points. Deleting the Bench already relieved most of the pressure.
- **Rewriting the render natively** in AVFoundation or Core Image. ADR 0008: the framework
  colour-matches every pixel and would reintroduce *bleached*, `h264_videotoolbox` has no CRF, and
  the chain's measured failures do not transfer.
- **Python linting.** A handful of small generator scripts. Run `ruff` once if it bothers you.
