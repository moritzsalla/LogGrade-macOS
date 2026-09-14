# Backlog

Everything raised and not finished. Ordered by what blocks what, not by size.

**Inherited from the precursor.** Most of what follows was written about that shoot and still reads
as true of the engine; the app's own work is tracked outside this file. `PROVENANCE.md` says what
came across.

## The concept change: the tool stops assuming one shoot

The pipeline was built for one shoot delivered to one platform. These are the pieces of that
assumption, in the order they block each other. The first three are done; what remains is here so
it is not re-derived.

**Done — a deliverable is data** (ADR 0010). Any `name:aspect-w:aspect-h[:offset]`, with Instagram's
two as presets. Byte-identical at defaults, confirmed against the precursor.

**Done — the exposure reference can come from the shoot** (ADR 0011). `MATCH=batch`. The default is
still `look.json`'s 609, which is one frame of one clip.

**Done — the crop offset has no default** (ADR 0010). It was 750, IMG_0609's framing. A
deliverable that crops is now refused without an offset, for one clip as readily as for twenty, and
`CROP_Y=centre` is the explicit way to say a clip does not need one. Centre was rejected as a
*default* for the reason the README gives: a batch centred by default gives files that all look
finished and are all framed wrong.

**Done — the Bench is deleted** (ADR 0007, superseded). Three implementations of the tone and trim
arithmetic became two.

**Done — the on-picture crop box follows the deliverable.** `CropGeometry` defaulted to 4:5 and
`GradeModel` never passed an aspect, so the box drawn on the preview was a Feed window whatever was
ticked. The aspect is now required at the call site, which is what stops it recurring, and a test
ties the box to the arithmetic `crop_prefix` uses.

**Two-dimensional crop geometry — blocked, and not by size.** The entry here used to say this
"roughly doubles the deliverable work" and should be done alongside the crop box. That was wrong
about the reason. `crop_prefix` emits `crop=<sw>:<ch>:0:<y>`: the window is ALWAYS the full source
width, x is always 0. It could only be narrower than the source if the deliverable's aspect were
taller than the source's, and that is exactly the case the function refuses (`crop window 2160x6480
is taller than the source 2160x3840`). So with portrait-only ingest there is no horizontal freedom
to expose, and building a 2D picker would add a control with nothing behind it.

It becomes real only when ingest accepts sources that are not portrait, which is ADR 0005's
territory: `require_portrait` refuses them on purpose, because the failure it prevents is a
landscape master silently squashed into a vertical frame. Reopen this with that decision, not
before.

**Sharpen and grain at other frame sizes.** The sharpener's radius follows the output height and its
amount does not, and the grain was sized at 1080 — an assumption, stated as one in
`delivery_image_chain`, never a measurement. Opening the deliverable set up makes other sizes easy
to reach, so this went from theoretical to reachable. It is a MEASUREMENT task, not a coding one:
render the same clip at several heights and look at them. Until then the README and
`03-final.sh`'s header both say other sizes are untuned.

**An editor for arbitrary shapes in the app.** The engine and the project file carry any shape; the
interface generates toggles from `Deliverable.presets` and lists anything else read-only. Adding a
preset costs no UI work, which was the point; authoring one in the app is not built.

**Done — `USAGE.md` exists.** The environment knobs, the deliverable spec grammar and the named
refusal codes live there now, rather than only in `grade.sh`'s header.

**The parity tolerance is carried forward, not measured.** `grade_worst_by_case` in the golden used
to be computed from the Bench's JavaScript; with the Bench gone, `--regenerate` copies it forward
and says so loudly. As a regression ceiling that is correct — a chain change that widens the real
divergence turns `LiveGradeTests` red, which is the point. What is missing is a way to re-measure
the ceiling deliberately when a change is meant to move it.

## Blocking the rest of the shoot

**Sign off the v4 look.** The current proof carries four changes on top of the approved grade:
black point lifted 0.015 → 0.025 with gamma eased 2.09 → 2.02 (shadow detail), stabilisation,
chroma-only denoise for the sign shimmer, and clustered grain moved after the sharpener. Until
that is judged, the rest of the shoot should not be rendered against it.

**Run the remaining clips.** Per-clip procedure in `docs/BATCH_RUNBOOK.md`. One thing there is
per-clip and must not be inherited from IMG_0609: the Feed crop offset, since 750 is this clip's
composition only. The engine now refuses rather than inheriting it.

## Worth doing next

**Judge the grain strength by eye.** `GRAIN_STRENGTH=8` is a starting suggestion, not a decision.
The measurements behind clustered-vs-per-pixel grain are settled (see `docs/PIPELINE.md`); the
amplitude is the one number that wants an eye. Override with `GRAIN_STRENGTH=n ./scripts/…`.

**Tonal weighting for grain.** Real film grain peaks in the midtones and falls off in deep shadow;
the current grain is flat across the tonal range. Needs a luma-derived mask via `geq`. Untested.

**Audio.** Measured and clean — PCM stereo, unclipped, 24 dB crest, genuine L/R decorrelation
(0.54), no lossy codec ever applied. Two things available: a high-pass around 60–80 Hz removes
rumble that is currently the loudest thing in the file, and a separate ambience recording (phone
set down, not held) would get street detail that handheld capture cannot. Nothing to undo first.

## Cleanups

**`02-grade.sh`'s header uses "look" twice for two different things.** Once for the Portra LUT,
once for the whole grade. One-line fix next time that file is open.

**`dist/proofs/` is doing three jobs** — proofs, variant renders, and ladder images. Nothing
references the folder, so splitting it is free whenever the naming settles.

~~**A fifth ADR.**~~ Written, as `docs/adr/0007_THE_GRADE_IS_DECIDED_IN_A_BENCH_AND_SENT_AS_DATA.md`.
The item said "a fifth" when six already existed, which is what a count in prose does.

## Considered and declined

Kept here so they are not re-litigated from scratch.

- **A better Portra LUT.** Every freely reachable one is the same coarse 13³ G'MIC grid. A real
  improvement means a print-film emulation (Kodak 2383 class), which expects log or Cineon input —
  a different pipeline shape, not a drop-in swap.
- **The scene-linear filmic route.** Architecturally correct and it lost on colour; kept in
  `luts/filmic/` with its measurements. See ADR-0002.
- **Collapsing the tone curve and the trims into the shared cube.** The OpenColorIO shape: one
  transform artifact consumed by the preview and the render both, so they agree by construction
  rather than by test. The three colour cubes already work that way. Measured against it: flattening
  stages onto one grid cost 55 code values against 48 for sampling in sequence, because the film
  look's own grid is only 13 points. Deleting the Bench also took three implementations to two, so
  the pressure this would relieve is largely gone.
- **Rewriting the render natively**, in AVFoundation or Core Image. ADR 0008 has the three
  measurements: the framework colour-matches every pixel and would reintroduce *bleached* through
  the framework rather than through a tag, `h264_videotoolbox` has no CRF, and the chain is the
  residue of measured failures that do not transfer.
- **Python linting.** Two scripts, ~300 lines. Run `ruff` once if it bothers you.
