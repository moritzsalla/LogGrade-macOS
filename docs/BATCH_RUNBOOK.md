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
5. **Pick the Feed crop offset** — pull one or two crop candidates from the graded master at
   different vertical offsets, look at them, pick one. Don't reuse IMG_0609's offset (750) blindly;
   composition differs per clip, and `grade.sh` now refuses `FEED=1` across several clips unless
   you pass `CROP_Y` explicitly.
6. **On sign-off, run the real finals**:
   - `./scripts/03-final.sh IMG_XXXX reels`
   - `./scripts/03-final.sh IMG_XXXX feed <crop_y>`
7. **Clean up**: once both finals are confirmed good, delete that clip's
   `dist/01-baseline/<clip>_baseline.mov` and `dist/02-graded/<clip>_graded.mov` — see
   docs/PIPELINE.md's disk space policy. Keep only `dist/03-final/*` for that clip going forward.

## Running a grading session (the Grade Bench)

The grade is decided by eye in the Grade Bench — `bench/`, a browser tool published as an
Artifact. (**Bench** is the term — see `CONTEXT.md`. In this trade a grader is a person, which is
why the folder is not called that.) It exists because the alternative
(render a proof → watch it → describe the problem in words → Claude reinterprets → render again)
costs a round trip per adjustment and loses information at both the "describe" and "reinterpret"
steps.

**To grade a clip:**

1. Extract a frame from the **baseline, with the look LUT applied but no tone stage** — that is
   exactly the input the tone LUT sees, so the preview matches the render. (The Bench's own hint
   says only "post-CST, pre-tone"; post-*look* is the part it leaves out, and a frame without the
   look in it will mispredict every reading.)
   ```bash
   ffmpeg -y -i dist/01-baseline/IMG_XXXX_baseline.mov -ss 4 -frames:v 1 \
     -vf "lut3d=file='luts/looks/kodak_portra_400_nc.cube':interp=tetrahedral,scale=810:-1" \
     -q:v 3 frame.jpg
   ```
2. Open the Artifact, drag the frame in (or use "Open frame…").
3. Place the reference samplers: click a reference name in the panel, then click that object in the
   picture. They are **not** at fixed coordinates across shoots — a plate or sign is wherever it is.
4. **Load the current `look.json` first** — paste it into the "load the current look.json" panel
   and press Load. The sliders then start from the shipped look rather than from generic defaults,
   and the blocks the Bench does not edit (`grain`, `stabilisation`, `match`) are carried through
   into its output. Without this the emitted file is incomplete and every stage aborts on the first
   missing key, because `look()` deliberately has no fallbacks.
5. Grade with the sliders. The readouts show each reference against its RAL spec live.
6. Add a note if the numbers don't capture it, and hit **Send grade**.

Claude reads the result from the artifact's db (`grades` collection) — each entry carries the
parameters, the measured readings, the note and the clip name.

**The tool's curve maths is a port of `make-tone-lut.py`** and it applies the curve to luma only,
mirroring `mergeplanes=0x001112`. Keep them in step: if one changes, change the other, or the
preview stops predicting the render.

**Republishing:** the source of truth is `bench/index.html`. The Artifact tool will only
publish from the working directory or the session scratchpad, so copy it there first and publish
from the copy; pass the artifact's existing URL to update in place rather than creating a second
one.

**Two fidelity caveats to keep in mind while grading:** the preview frame is an 8-bit JPEG, so very
fine gradients look slightly rougher than the 10-bit render; and objects in shade read darker and
less saturated than their RAL spec, so the references are hue and ratio guides, not exposure ones.

## Orientation

The pipeline contains no rotation logic and assumes the source plays the right way up. The one
guard, `require_portrait`, refuses a non-portrait clip in the delivery stage rather than letting it
be squashed into 1080x1920. The reasoning, and the mixed-orientation episode that blocked this
shoot's batch for hours, are in `docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md`, which is the
only copy.

## What's safe to batch, what isn't

Safe to loop unattended: the mechanical stages, given a proof that has been signed off. What is
never safe to batch is the Feed crop, because its offset is a composition call per clip; step 5
above says what `grade.sh` does about that. This pipeline is "scripted mechanics, per-clip human gate," not "point at the folder and walk away."
