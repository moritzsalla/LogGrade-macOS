# loggrade

A Mac app for grading iPhone ProRes + AppleLog footage, built on a measured ffmpeg chain.
**Personal use tool, never distributed.**

**Where this came from.** The render chain is a fork of `ffgrade`, taken at one commit and frozen
there. `PROVENANCE.md` records what was inherited, what debt came with it, and why the original is
not being changed. Everything below Usage describes that inherited engine and is accurate today.

**Where it is going.** Drop clips, see the graded picture, adjust, pick a crop and a delivery
format and a folder, hit Convert. The engine stays the shell chain and the app drives it, never
rebuilding its filter graph. `tests/conformance.sh` is what keeps that honest.

**Why?** iPhone Pros 15th generation and newer are able to shoot in log which retains enough depth to edit professionally. Apple log preserves enough dynamic range, shadow detail, and color depth (10-bit) to be seamlessly edited alongside footage from professional cinema cameras.

Getting there requires an understanding of color spaces, LUTs, and exposure, and often requires professional software. This tool gets about as much image quality out of iPhone footage as the format actually holds without opening any editing programs. The final LUT is designed to look like Kodak Portra but can be tweaked.

**How?** **Apple Log → graded Rec.709 in one ffmpeg pass.** 10-bit preserved to delivery, tone curve
applied to luma only, LUTs generated rather than guessed. No NLE.

**Does it work?** Very well. Log holds roughly 3.6 stops of highlight headroom above diffuse white,
10-bit 4:2:2, and none of the HDR tone mapping or sharpening a normal phone capture bakes in.
Getting that out of it is a tone problem, and tone is something ffmpeg can do properly.

![Tone ladder](docs/grade-ladder-tone.png)

![Workbench](docs/grade-bench.png)

## Usage

```sh
# drop clips in src/, then:
./scripts/grade.sh src/                  # whole folder → dist/03-final/
./scripts/grade.sh src/IMG_0609.mov      # one clip

PROOF=2 ./scripts/grade.sh src/IMG_0609.mov   # 2s through the real chain → dist/proofs/
STAB=0 ./scripts/grade.sh src/           # skip stabilisation, faster
DRY=1  ./scripts/grade.sh src/           # plan only, render nothing

FEED=1 CROP_Y=750 ./scripts/grade.sh src/IMG_0609.mov   # also emit the 4:5 Feed crop
```

Roughly 3 minutes per clip. Output lands in `dist/03-final/`, a per-run report in `dist/reports/`.

`PROOF` is the one to reach for first: it renders a couple of seconds through the identical filter
chain, so a look can be judged in seconds instead of minutes. The Feed crop needs `CROP_Y` because
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

![The Grade Bench](docs/grade-bench.png)

The Bench is a browser tool for setting the look by eye. Export a frame, drop it in, drag sliders,
and the image updates instantly — no render round-trip. The calibration readouts sit beside the
sliders so you can see when a change pushes a known colour off its spec.

**Paste the current `look.json` into the Bench's load panel before you start**, or the emitted
file comes back incomplete and every stage stops on the first missing key. `look()` has no
fallbacks, deliberately, because a silent substitution would be a different look. The full
grading-session procedure is in `docs/BATCH_RUNBOOK.md`.

When it looks right, hit **Send grade** and the settings come back as `look.json`, the single
source every stage reads. Change that file and the tone LUT regenerates itself on the next run:
each generated `.cube` carries its own parameters in its `TITLE`, and a mismatch means rebuild. It
is checked by content rather than by timestamp, because git does not preserve timestamps and a
fresh clone would otherwise trust a stale cube forever.

The Bench's curve maths is a port of the renderer's. `tests/curve-parity.py` runs both over the
same inputs and fails if they diverge — otherwise the preview could quietly stop predicting the
render and nothing would say so.

## Caveats

Built for my footage, my machine, my deliverables. macOS on Intel, bash 3.2, ffmpeg from
`~/.local/bin`. Output is hardcoded to Instagram's two shapes. The look is one I like; yours will
differ, which is what `look.json` and the Bench are for.

**It will never be published.** Unlike its precursor it does have a roadmap: a native
app over this engine, with the chain parameterised rather than frozen.

Deliverables per clip: **Reels/Stories** (9:16, 1080×1920) and **Feed** (4:5, 1080×1350).

Reference footage throughout the docs is a 19-clip set shot on an iPhone 15 Pro in the Final Cut
Camera app: ProRes 422 HQ, Apple Log, 4K24, locked white balance and focus.

## How it works, exactly

One ffmpeg invocation per clip, source to deliverable. In order:

1. **Apple Log → Rec.709** via Apple's own 65³ conversion LUT. The transfer function is
   proprietary, so this is a lookup, not a curve anyone can derive.
2. **Look LUT** — Kodak Portra emulation. Supplies colour character and almost no contrast.
3. **Tone curve**, generated from `look.json`, applied to the **luma plane only**. The original
   chroma is merged back untouched, which is what stops a contrast curve turning saturated colour
   neon.
4. **Saturation and warmth**, also from `look.json`.
5. **Stabilisation**, if a `.trf` exists for the clip, applied at full resolution before the
   downscale so the warp resamples at 4K.
6. **Chroma-only denoise** — removes fringing on high-contrast edges that saturation amplifies.
7. **Downscale to 1080p** with Lanczos, dithered on the 10→8 bit reduction.
8. **Sharpen**, then **grain**, in that order. Grain is generated at half resolution and blended,
   so it survives Instagram's re-encode instead of being smeared into blobs.
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
dist/           Everything generated. Gitignored.
  01-baseline/    staged pipeline only: after the Log→Rec.709 conversion
  02-graded/      staged pipeline only: the ProRes master
  03-final/       deliverables
  proofs/         short renders through the real chain, for judging before a full render (PROOF=)
  ladders/        side-by-side comparison stills, assembled by hand
  stab/           camera-motion transforms, per clip
  reports/        what each run did
scripts/        The pipeline. Start at lib.sh.
bench/          The Grade Bench (published as a browser tool).
luts/
  apple/          Apple's conversion LUTs — NOT committed, see SOURCE.txt to fetch them
  looks/          film-emulation LUTs (MIT)
  tone/           shipped.cube, generated from look.json
look.json       The look. One source, every stage reads it.
docs/           PIPELINE.md is the real documentation.
  BATCH_RUNBOOK.md  per-clip procedure, and which calls are not safe to automate
  SHOOTING_SETUP.md how to shoot for this pipeline, and what the first shoot measured
  adr/            decisions that would be expensive to reverse, with the measurements
tests/          bats suite + the curve parity check.
CONTEXT.md      What each word means here.
```

## Tests

I added some basic tests, mainly because running the pipeline is expensive and I didn't want to
discover mid-conversion that a guard had broken.

Run everything with `./scripts/check.sh`:

- **shellcheck** across every script.
- **`tests/curve-parity.py`** — the important one. Runs the Bench's JavaScript and the Python
  generator over the same inputs and fails if they disagree by more than one 8-bit code value. If
  these drift, the browser preview stops predicting the render and nothing else would catch it.
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
