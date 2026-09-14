# Backlog

Everything raised and not finished. Ordered by what blocks what, not by size. Finished work is not
kept here: its reasoning lives in the ADR or commit that did it.

Most entries were inherited from the precursor and written about its one shoot; `PROVENANCE.md`
says what came across. The universal-app work has its own plan in `docs/UNIVERSAL_APP_PLAN.md`.

## The point of the app

Give iPhone Apple Log footage an incredible look, very easily. Today it takes lots of input and still
doesn't look good. Judge every entry below by that, and by whether a non-technical photographer
could use the result. Work that changes nothing they see or can do waits.

## Next, in order

**1. The look, judged against the partner's analog scans.** The Portra LUT is a coarse community
emulation, so matching it means nothing; the reference is the partner's scanned film work. Needs a
few scans and iPhone clips of similar scenes. Measure tone, colour and grain against the scans; the
user judges by eye. ADR 0014 allows the default image to move (`tests/render-golden.sh --regenerate
"<why>"`). The v4 sign-off and the grain strength below are part of this.

**2. The universal app (#10)**, so the partner can run it on the Apple silicon Mac.
`docs/UNIVERSAL_APP_PLAN.md`.

**3. Landscape footage.** Must work; this reverses ADR 0005's portrait-only rule. Keep its
underlying guard: never silently squash landscape into a portrait deliverable. Unblocks 2D crop.

**4. Every film stage switchable off**, down to a plain Apple-CST colour-corrected export. Check what
is already possible before building.

## The app, as it feels to use

**An auto button.** One press gives a good starting grade for the clip, so most clips need no input.

**Sliders must feel instant on the Intel Mac.** The controls currently wait on the preview: the UI
feels coupled to how fast a frame grades. The slider has to move immediately and the picture follow
when it can (optimistic UI).

**Export is slow on the Intel Mac.** Measure where the time goes before choosing a fix.

**Sort the control sections in a logical order.** Currently not in the order someone grading thinks.

**Remove the time-progression UI next to the control sections.** The user finds it weird and has no
use for it.

**Question the print stage in the interface.** The user does not see why they would add a print look
to video footage. Either explain it in plain words or hide it; the engine keeps it.

**Replace the startup screen with a brief splash.** Like Photoshop's: show the licence for a moment,
then the normal window. Not a separate upload screen.

**Short, plain labels and help text.** Many labels are still long and quirky. Help text must be
understandable by anyone, not only by someone who knows grading.

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

**Two-dimensional crop geometry — follows landscape footage (Next, 3).** `crop_prefix` always
takes the full source width at x=0, because with portrait-only ingest there is no horizontal
freedom. Once landscape sources are accepted, a 2D picker has something behind it.

**Three defaults kept only for the precursor's sake (ADR 0014).** Decide on the merits: ADR 0011's
`MATCH=1` default; the exposure probe's inherited, unmeasured `-ss 1` and `scale=320:-1`; the
stabiliser's `unsharp=5:5:0.2`.

## Considered and declined

Kept here so they are not re-litigated from scratch.

- **A better Portra LUT.** Every freely reachable one is the same coarse 13³ G'MIC grid. The
  reference is now the partner's scans instead (Next, 1), not a better copy of this LUT. The
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
