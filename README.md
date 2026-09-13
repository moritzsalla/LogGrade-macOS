# ffgrade-macOS

A Mac app for grading iPhone ProRes + AppleLog footage, built on a measured ffmpeg chain.
**A personal tool, shared to read rather than to ship.**

**Licence: [PolyForm Noncommercial 1.0.0](LICENSE).** Read it, run it, change it, share it — for
anything that is not commercial, and keep the attribution with it. Selling it or using it in a
business needs separate permission; ask. Two carve-outs, both in `LICENSE`: the film-emulation
cubes in `luts/looks/` are somebody else's MIT-licensed work and keep their own terms, and Apple's
conversion LUT is deliberately absent because its licence forbids redistributing it.

**Where this came from.** The render chain is a fork of `ffgrade`, taken at one commit and frozen
there. `PROVENANCE.md` records what was inherited, what debt came with it, and why the original is
not being changed. Everything below Usage describes that inherited engine and is accurate today.

**What a fresh clone cannot do.** Two things, both on purpose. Apple's conversion LUT is not here
and has to be downloaded once — `luts/apple/SOURCE.txt` says how, and nothing renders until it is.
And `tests/conformance.sh`, which asserts this fork still produces bytes identical to its
precursor, needs that precursor checked out beside it; without it the test skips rather than
failing. So the claim holds here and is not something you can verify from a clone.

**What it is.** A Mac app over that engine: drop clips, see the graded picture, adjust, pick a
crop and a delivery format, hit convert. The app sets environment variables and reads the engine's
event stream — it never builds a filter graph, and a test renders one clip both ways and asserts
the bytes match, so that cannot quietly stop being true.

```sh
./app/make-app.sh                  # builds dist/LogGrade.app, optimised
./app/make-app.sh --debug          # unoptimised; the live preview is unusable, see below
swift test --package-path app      # the app's own suite, about a minute
./scripts/check.sh                 # lint, grade parity, bats, and the Swift suite
./scripts/check.sh --conformance   # plus: still byte-identical to the precursor?
```

![LogGrade](docs/app.png)

## Using it

Drop clips on the window, or File ▸ Add Clips. Pick one, open a stage in the inspector, and move a
control: the picture follows it. Let go and the engine renders the same frame exactly. Choose the
deliverables and a folder, then Convert.

- **The picture follows every control**, including exposure and white balance, which run before
  Apple's conversion and so cannot be recovered from a converted frame. While a control moves, the
  whole chain runs in the app on a decoded source frame — 1ms for a tone move, 4ms for a film look.
  The live picture is within about 1.3 code values of the render, measured on real footage, and the
  panel always says which of the two you are looking at. There is no preview button: every path
  that changes the look renders on release by itself.
- **Build it optimised.** The live preview is a tight loop over half a million cube samples, and a
  debug build takes 1.5 seconds per frame against 12.7ms. That is why `make-app.sh` takes `--debug`
  rather than `--release`.
- **Deliver at 1080 × 1920.** Instagram re-encodes to 1080 wide, so 2160 costs four times the
  render for nothing downstream — and the grain and sharpener were tuned at 1080 and are merely
  scaled above it. The delivery panel counts the render passes before you start, because two
  deliverables plus stabilisation is three passes over every clip.
- **The crop is dragged on the picture**, per clip, because the offset is a composition call and
  one clip's framing applied to a batch produces files that all look done. It can also be typed and
  nudged with the arrow keys. A Feed render is blocked until every clip has one, and Convert says
  which clip is missing rather than just being grey.
- **Clips are measured before they are accepted.** Already-converted footage is refused, since
  grading it again applies Apple's conversion twice.

Two habits worth knowing: hold **C** to see the picture before the change you are making, and
**double-click a control's name** to put it back to the preset's value.

`docs/adr/0009_THE_PREVIEW_STAYS_EXACT_UNTIL_THE_DIVERGENCE_IS_EXPLAINED.md` carries the preview's
measurements and what licenses each piece of maths that had to be written twice.
`docs/APP_DESIGN.md` carries the interface decisions.

**Why?** iPhone Pros 15th generation and newer are able to shoot in log which retains enough depth to edit professionally. Apple log preserves enough dynamic range, shadow detail, and color depth (10-bit) to be seamlessly edited alongside footage from professional cinema cameras.

Getting there requires an understanding of color spaces, LUTs, and exposure, and often requires professional software. This tool gets about as much image quality out of iPhone footage as the format actually holds without opening any editing programs. The final LUT is designed to look like Kodak Portra but can be tweaked.

**How?** **Apple Log → graded Rec.709 in one ffmpeg pass.** 10-bit preserved to delivery, tone curve
applied to luma only, LUTs generated rather than guessed. No NLE.

**Does it work?** Very well. Log holds roughly 3.6 stops of highlight headroom above diffuse white,
10-bit 4:2:2, and none of the HDR tone mapping or sharpening a normal phone capture bakes in.
Getting that out of it is a tone problem, and tone is something ffmpeg can do properly.

![Tone ladder](docs/grade-ladder-tone.png)

## Driving the engine directly

The app is the way to use this. Everything below still works and is what the app drives — it sets
these variables and reads the engine's events, and a test renders one clip both ways and asserts
the bytes match. Reach for it when you want a batch without a window, or to see what the app is
actually doing.

```sh
# drop clips in src/, then:
./scripts/grade.sh src/                  # whole folder → dist/03-final/
./scripts/grade.sh src/IMG_0609.mov      # one clip

PROOF=2 ./scripts/grade.sh src/IMG_0609.mov   # 2s through the real chain → dist/proofs/
FRAME=4 ./scripts/grade.sh src/IMG_0609.mov   # one graded still → dist/frames/
STAB=0 ./scripts/grade.sh src/           # skip stabilisation, faster
DRY=1  ./scripts/grade.sh src/           # plan only, render nothing

FEED=1 CROP_Y=750 ./scripts/grade.sh src/IMG_0609.mov   # also emit the 4:5 Feed crop
LOOK=none ./scripts/grade.sh src/IMG_0609.mov           # no film emulation, just tone
HEIGHT=2160 ./scripts/grade.sh src/IMG_0609.mov         # deliver taller than 1080p
JSON=1 ./scripts/grade.sh src/           # machine-readable events instead of prose
```

Roughly 3 minutes per clip. Output lands in `dist/03-final/`, a per-run report in `dist/reports/`.

`FRAME` is the cheapest way to see a grade: one still through the real chain, no delivery stage,
which is what the app's preview uses. `PROOF` is the next one up — a couple of seconds through the
identical chain including grain, sharpening and the encode, so a deliverable can be judged before
committing to the full render. A preview answers "is this the grade"; a proof answers "is this
deliverable", and `CONTEXT.md` keeps the two words apart. The Feed crop needs `CROP_Y` because
its offset is a composition call per clip, and a run across several clips is refused without one
rather than quietly applying one clip's framing to all of them. The full list of knobs is in
`scripts/grade.sh`'s header.

## Before touching anything

- **`src/` is read-only.** Everything generated goes to `dist/`.
- **Read `docs/PIPELINE.md`** before changing the render chain. It records what was tried and
  failed, with measurements — most of the filter choices look arbitrary until you see why the
  obvious alternative was rejected.
- **Run `./scripts/check.sh`** after touching anything in `scripts/`.
- **Orientation is the source's problem.** Clips must already play the right way up; the pipeline
  refuses anything that isn't portrait rather than squashing it.

## Tweaking the final pass LUT

Open the app and move the sliders. The picture follows them, and letting go renders the same frame
through the real chain. That is what this fork exists for.

### The Bench, which the app replaced

![The Grade Bench](docs/grade-bench.png)

`bench/` is the precursor's browser tool for setting the look by eye: export a frame, drop it in,
drag sliders, no render round-trip. The app does the same job against the real chain rather than a
pre-baked JPEG, so the Bench is kept for one reason only — `tests/grade-parity.py` slices its pixel
function out and measures it against ffmpeg's own output, which is one of the two tests licensing
the app's live preview. Everything below about it is inherited and still accurate.

**Paste the current `look.json` into the Bench's load panel before you start**, or the emitted
file comes back incomplete and every stage stops on the first missing key. `look()` has no
fallbacks, deliberately, because a silent substitution would be a different look. The full
grading-session procedure is in `docs/BATCH_RUNBOOK.md`.

When it looks right, hit **Send grade** and the settings come back as `look.json`, the single
source every stage reads. Change that file and the tone LUT regenerates itself on the next run:
each generated `.cube` carries its own parameters in its `TITLE`, and a mismatch means rebuild. It
is checked by content rather than by timestamp, because git does not preserve timestamps and a
fresh clone would otherwise trust a stale cube forever.

The Bench's grade maths is a port of the renderer's. `tests/grade-parity.py` runs both over the
same inputs and fails if they diverge — otherwise the preview could quietly stop predicting the
render and nothing would say so.

## Caveats

Built for my footage, my machine, my deliverables. macOS on Intel, bash 3.2, ffmpeg from
`~/.local/bin`. The two Instagram shapes are the defaults rather than the only options now: height,
frame rate and the crop aspect are arguments, and a frame rate that would need retiming is refused
rather than interpolated. The look is one I like; yours will
differ, which is what `look.json` and the Bench are for.

**It will never be published.** Unlike its precursor it does have a roadmap: a native
app over this engine, with the chain parameterised rather than frozen.

Deliverables per clip: **Reels/Stories** (9:16, 1080×1920) and **Feed** (4:5, 1080×1350).

Reference footage throughout the docs is a 19-clip set shot on an iPhone 15 Pro in the Final Cut
Camera app: ProRes 422 HQ, Apple Log, 4K24, locked white balance and focus.

## How it works, exactly

One ffmpeg invocation per clip, source to deliverable. In order:

0. **Input correction**, if it is not neutral: exposure, white balance and an ASC CDL, generated
   into one cube from `look.json`. It runs *before* the conversion, in log, because Apple Log holds
   about twelve stops that the conversion lands on a display ceiling of 1.0 — corrected afterwards,
   the same move clips highlights the source still has. A neutral correction leaves the filter out
   of the graph entirely rather than rendering every pixel through a lookup that returns it.
1. **Apple Log → Rec.709** via Apple's own 65³ conversion LUT. Apple published the log transfer
   function, so the log-to-linear half is reproducible — but this cube also carries a display
   rendering that Apple has not published, which is why it stays a lookup.
2. **Look LUT** — Kodak Portra emulation by default, chosen in `look.json` and selectable per
   run. Supplies colour character and almost no contrast. `none` removes it from the graph.
3. **Tone curve**, generated from `look.json`, applied to the **luma plane only**. The original
   chroma is merged back untouched, which is what stops a contrast curve turning saturated colour
   neon.
4. **Saturation and warmth**, also from `look.json`.
5. **Stabilisation**, if a `.trf` exists for the clip, applied at full resolution before the
   downscale so the warp resamples at 4K.
6. **Chroma-only denoise** — removes fringing on high-contrast edges that saturation amplifies.
7. **Downscale** with Lanczos, dithered on the 10→8 bit reduction. 1080p by default; the height
   is a knob and the width follows the deliverable's aspect.
8. **Sharpen**, then **grain**, in that order. Grain is generated at half resolution and blended,
   so it survives Instagram's re-encode instead of being smeared into blobs. The sharpener's radius
   scales with the output height, because its measured 5x5 is in pixels; the grain needs no such
   adjustment, since a half-size plate scales with the frame already.
9. **H.264 encode**, then a remux pass that stamps and verifies the Rec.709 tags — encoders don't
   reliably write them, and a wrongly tagged file gets double-transformed by any player that
   trusts the tag.

Exposure is matched per clip against a reference before the tone curve, so a shoot grades
consistently without hand-tuning each file.

The staged scripts (`01-baseline` → `02-grade` → `03-final`) do the same work in separate passes,
writing ProRes intermediates. They exist for re-tuning a look without redoing the conversion. Since
the look is settled, `grade.sh` skips them — measured 2.3× faster with no intermediates written.

**One deliberate difference between the two paths:** `grade.sh` solves each clip's gamma against
the exposure the look was tuned at, and the staged path applies `look.json`'s gamma raw. So the
same clip renders slightly different tone through each, by design. `MATCH=0` turns the solve off
and makes them agree.

## Layout

```
src/            Drop footage here. Read-only, gitignored.
dist/           Everything generated. Gitignored whole, and created on demand — every stage
                makes its own output directory, so none of the folders below exists on a clone.
  01-baseline/    staged pipeline only: after the Log→Rec.709 conversion
  02-graded/      staged pipeline only: the ProRes master
  03-final/       deliverables
  proofs/         short renders through the real chain, for judging before a full render (PROOF=)
  frames/         stills for the app's preview: the graded one it judges, and the ungraded
                  source frame it grades itself while a control is moving (FRAME=, FRAME_STAGE=)
  ladders/        side-by-side comparison stills, assembled by hand
  stab/           camera-motion transforms, per clip
  reports/        what each run did
scripts/        The pipeline. Start at lib.sh.
bench/          The precursor's browser Bench. The app replaced it; it is kept because the
                parity harness measures its pixel function against ffmpeg's own output.
luts/
  apple/          Apple's conversion LUTs — NOT committed, see SOURCE.txt to fetch them
  looks/          film-emulation LUTs (MIT)
  tone/           shipped.cube, generated from look.json
look.json       The look. One source, every stage reads it.
docs/           PIPELINE.md is the real documentation.
  BATCH_RUNBOOK.md  per-clip procedure, and which calls are not safe to automate
  SHOOTING_SETUP.md how to shoot for this pipeline, and what the first shoot measured
  adr/            decisions that would be expensive to reverse, with the measurements
tests/          bats suite, the grade parity harness, the conformance check against the
                precursor, and the recorded event stream the app parses.
app/            the Mac app. GradeKit is the engine adapter and the models, tested from the
                terminal; LogGrade is the window. make-app.sh assembles the bundle and vendors
                the engine and ffmpeg into it, since a launched app inherits no useful PATH.
CONTEXT.md      What each word means here.
```

## Tests

I added some basic tests, mainly because running the pipeline is expensive and I didn't want to
discover mid-conversion that a guard had broken.

Run everything with `./scripts/check.sh`:

- **shellcheck** across every script.
- **`tests/grade-parity.py`** — the important one. Measures the Bench's JavaScript against
  ffmpeg's own output over a committed probe and fails on a disagreement bigger than the recorded
  tolerance. It is one of the two tests that license the app's live preview to exist at all.
- **`swift test --package-path app`** — the app's own suite, about a minute. Most of it needs no
  ffmpeg, but the ones that matter most do: `LiveChainTests` grades a real frame in-process and
  measures it against the engine's render of the same frame, `Cube3DTests` holds the interpolation
  to ffmpeg's `lut3d` on a deliberately non-smooth cube, and `CorrectionCubeTests` compares every
  one of 107,811 numbers against the generator it replaced. `check.sh` runs it too.
- **`tests/lib.bats`** — the bats suite. Most of it covers the safety layer: colour-tag
  verification, the portrait guard, disk-space checks, work-dir resolution, transform freshness,
  and that neither a failed remux nor a failed re-render destroys the file it was replacing. A few
  are smoke tests that just check the scripts start and run, which sounds trivial until the whole
  suite passes green while four functions are missing and nothing can execute. That happened.
  One test renders a fraction of a second of real footage through the production filter graph,
  because nothing else in the suite executes it and shellcheck cannot see inside a filter string.

  The count is deliberately not written down here. `check.sh` prints it, and a number in prose goes
  stale by construction — this line said 20 while the suite said 42.

Every test exists because the thing it covers already broke, and two of the guards shipped broken
and went unnoticed until something exercised them. The suite has been mutation-tested — each guard
deliberately broken to confirm the matching test goes red — which is how I found two tests that
passed against a removed guard and were doing nothing.
