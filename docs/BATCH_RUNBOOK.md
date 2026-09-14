# Running the pipeline on a new clip

The mechanical steps (LUT application, tag fixing, encoding) are scripted in `scripts/`.
The judgment calls below are NOT scripted — they can't be safely automated in a blind loop and
need a preview frame actually looked at, per clip. White balance and the Feed crop each have a
per-clip answer, and each has already been got wrong by assuming the previous clip's
(see docs/PIPELINE.md, "Mistakes made", and ADR 0005 on orientation).

## Per-clip procedure

1. **Baseline**: `./scripts/01-baseline.sh IMG_XXXX`
2. **Check white balance** — sample a real neutral reference in the frame (road, sidewalk, an
   overcast sky — not a colored surface) and confirm it reads close to neutral (R≈G≈B). WB was
   locked at capture, so this should hold across clips, but "should" isn't "confirmed" — spot
   check, don't skip because it's tedious.
3. **Grade**: `./scripts/02-grade.sh IMG_XXXX`
4. **Proof** — `PROOF=2 ./scripts/grade.sh src/IMG_XXXX.mov` renders two seconds through the real
   delivery chain into `dist/proofs/`. Get sign-off on that before committing to the slow render.
   It is the same chain, not a lookalike: the previous instruction here was to reproduce "the same
   filter chain as the real export" by hand, which meant a fourth copy of the chain existing
   nowhere in `scripts/`.
5. **Pick the crop offset** for any deliverable that crops — pull one or two candidates from the
   graded master at different vertical offsets, look at them, pick one. Don't reuse IMG_0609's
   offset (750) blindly; composition differs per clip, and `grade.sh` refuses a cropped deliverable
   outright unless you pass `CROP_Y` — there is no default. `CROP_Y=centre` is how you say this
   clip does not need a considered one.
6. **On sign-off, run the real finals**. A deliverable is a preset name or `name:aspect-w:aspect-h`:
   - `./scripts/03-final.sh IMG_XXXX reels`
   - `./scripts/03-final.sh IMG_XXXX feed <crop_y>`
   - `./scripts/03-final.sh IMG_XXXX square:1:1 <crop_y>` — or any other shape
7. **Clean up**: once both finals are confirmed good, delete that clip's
   `dist/01-baseline/<clip>_baseline.mov` and `dist/02-graded/<clip>_graded.mov` — see
   docs/PIPELINE.md's disk space policy. Keep only `dist/03-final/*` for that clip going forward.

## Running a grading session (the app)

The grade is decided by eye in the Mac app, `dist/LogGrade.app` — `./app/make-app.sh` builds it.
Open a clip, move a control, and the picture follows; let go and the engine renders the same frame
through the real chain. The scopes read the rendered frame and draw the three RAL references beside
it, so a change that pushes a known colour off its spec is visible while you make it.

It replaced a browser tool, the Grade Bench, which was deleted — see
`docs/adr/0007_THE_GRADE_IS_DECIDED_IN_A_BENCH_AND_SENT_AS_DATA.md` for what carried over. The
substance did: the grade is still decided by eye against references in frame, and still leaves as
data in `look.json`. Only the venue changed. **If you are following an old note that tells you to
export a JPEG, drag it into an Artifact and paste `look.json` into a load panel, stop — none of
that exists.**

**To grade a clip:**

1. Open the app and add the clip. Already-converted footage is refused, since grading it again
   applies Apple's conversion twice.
2. Move the controls. Exposure and white balance run *before* Apple's conversion, so they are live
   too — that is why the app grades a decoded source frame rather than a converted one.
3. Watch the scopes. The references are places to measure from, not places to arrive at: the
   shipped grade sits deliberately off spec, which is ADR 0001.
4. Hold **C** to see the picture before the change you are making. Double-click a control's name to
   put it back to the preset's value.
5. Save. `look.json` is the output, and it is the only thing every stage reads.

**Without a Swift toolchain**, `look.json` is just numbers — edit it by hand and the tone LUT
regenerates itself on the next run, by content rather than timestamp. `FRAME=<seconds>
./scripts/grade.sh src/IMG_XXXX.mov` renders one still through the real chain into `dist/frames/`
to judge it, which is the same CST, the same look cube and the same solved tone curve.

**One fidelity caveat while grading:** objects in shade read darker and less saturated than their
RAL spec, so the references are hue and ratio guides, not exposure ones.

## Orientation

The pipeline contains no rotation logic and assumes the source plays the right way up. The one
guard, `require_portrait`, refuses a non-portrait clip in the delivery stage rather than letting it
be squashed into a vertical deliverable. The reasoning, and the mixed-orientation episode that blocked this
shoot's batch for hours, are in `docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md`, which is the
only copy.

## What's safe to batch, what isn't

Safe to loop unattended: the mechanical stages, given a proof that has been signed off. What is
never safe to batch is a crop offset, because it is a composition call per clip; step 5 above says
what `grade.sh` does about that. This pipeline is "scripted mechanics, per-clip human gate," not "point at the folder and walk away."
