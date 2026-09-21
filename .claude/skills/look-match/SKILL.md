---
name: look-match
description: Fit, tune or re-bake a film look (Portra 160, Portra 800, Super 8, any stock cube in luts/film/) against target images — the partner's analog scans, their edits, public scans or RawTherapee Hald CLUTs. Use whenever the user says a preset or look is too warm/cool/dark/saturated, "doesn't look like the scans", asks to match, calibrate, fit, tune or rerun the match, mentions the partner's scans, references/, spektrafilm, film emulation or stock matching, or ~/Documents/ffgrade-film-bake. Also covers where the bake toolchain lives and how a cube lands in the repo.
---

# Look match

Two routes, both outside git for licence reasons (spektrafilm is GPLv3; the cubes are CC BY-SA,
provenance in `luts/film/CHANGELOG.txt`). The target is never committed: `references/` and
`docs/research/` are in `.git/info/exclude`.

| Route | When | Target | Scorecard |
|---|---|---|---|
| **A. Calibrate** (`calib.py`) | Portra 160 and anything with the same scene on film and video | the partner's EDIT of the scan (`references/Ivy edit, 0N.png`), pixel-registered to video of the same scene | per class and scene |
| **B. Tune** (`scan_bake3.py` / `trim.py`) | stocks with only public references (Portra 800, Super 8) | RawTherapee Hald CLUT applied to our Neutral | per region |

Portra 800 is a derivative of 160 (the user's call): re-derive it after 160 moves, don't fit it alone.

## Where things are

- Toolchain: `~/Documents/ffgrade-film-bake/` (not git; the user's scratch project). Python is
  always `~/Documents/ffgrade-film-bake/venv/bin/python` (3.13: spektrafilm, numpy, scipy,
  scikit-image, PIL; install with `install.sh`, extra packages with
  `uv pip install --python <that python> ...`). System `python3` lacks these.
- Footage of the scanned scenes: `~/Movies/Nina facade plants prores shots/IMG_06xx.mov`.
  Scene A (pale brick, ivy) = IMG_0609, 0616; scene B (red brick, red and green ivy) = IMG_0618,
  0619, 0624. IMG_0624's sky is clipped in the source.
- Round log, method, findings and every scorecard: `docs/research/portra160-calibration/README.md`
  (local only, in the main checkout).
  Read its "Findings" before changing the model; each one is a failure already paid for. Every new
  tryout (script, round log, raw output, sheets) goes to `docs/research/<topic>/` too, kept as proof
  of method and never committed: the sheets show the partner's scans. Prefer the main checkout's
  copy; a worktree's is deleted with the worktree.
- `calib.py` (fit/proof/bake), `register_full.py`, `verify.py`, `crops.py` and the round caches live
  in `~/Documents/ffgrade-film-bake/calib/` (rescued from a purged /tmp scratchpad). Their paths are
  hard-coded at the top: `S` points at that folder, `WT` (where `bake` writes the cube) must be
  repointed at the current worktree before a run.

## Route A: calibrate against the scans

`new_cube(log) = C(stock(P(log)))`: `P` one tone curve before the spektrafilm stock cube, `C` curves,
a near-identity matrix and Oklab chroma/hue after it. Stages, run from the main checkout (the worktree
sandbox rejects commands with shell-variable paths and inline scripts; write scripts to files with
literal paths):

1. **Render inputs once, in parallel, each with its own work dir** (renders sharing one
   `GRADE_WORK_DIR` collide):
   ```sh
   V=~/Documents/ffgrade-film-bake/venv/bin/python; S=docs/research/portra160-calibration  # or a scratchpad
   M="$HOME/Movies/Nina facade plants prores shots"
   # the log exactly as it enters the cube: a temporary identity cube (never commit it)
   $V -c "import numpy as np;N=65;a=np.linspace(0,1,N);b,g,r=np.meshgrid(a,a,a,indexing='ij');open('luts/rendering/identity.cube','w').write('LUT_3D_SIZE 65\n'+'\n'.join('%.6f %.6f %.6f'%t for t in zip(r.ravel(),g.ravel(),b.ravel()))+'\n')"
   LOGGRADE_CACHE=$S/cache_log GRADE_WORK_DIR=$S/work_0609 LOOK_FILE=presets/portra160.json CONVERT=identity \
     FRAME=1 FRAME_HEIGHT=2400 ./scripts/grade.sh "$M/IMG_0609.mov" &   # one per clip, then wait
   rm luts/rendering/identity.cube
   ```
   Then `register_full.py` (SIFT + RANSAC homography of each scan onto its still → `full_<clip>.npz`).
   These are the cache; nothing in the loop re-renders. Re-render only when a pre-cube stage of the
   preset (correction, match, halation, grain) changed since the cache was made.
2. **Fit, in the background:** `$V calib.py fit > fit.log 2>&1 &` (2–6 min). It prints the scorecard for
   the cube it starts from (`old`, the shipped one: your baseline) and for the fit (`new`).
3. **Proof offline:** `calib.py proof` → `calib_<clip>.jpg` (before | new | partner edit).
4. **Bake:** `calib.py bake` → `luts/film/portra160.cube` in the worktree.
5. **Verify in the real chain:** render 0609 and 0618 with the new cube (`FRAME=1`), compare to the
   offline proof (`verify.py`). Halation, metering and grain are in the chain, not in the model.

## Route B: tune stock parameters

```sh
# from the repo root; the params are the JSON in the current cube's TITLE, edited. ~80 s per bake.
B=~/Documents/ffgrade-film-bake; V=$B/venv/bin/python
$V $B/scan_bake3.py $S/NAME.cube kodak_portra_800 '{...}' 2>&1 | grep -v Warning | tail -1
python3 .claude/skills/look-match/reencode-for-apple-display.py $S/NAME.cube luts/film/NAME.cube scripts
bash $B/looks/frames360.sh look.json neutral              # once: the Neutral stills the Hald is applied to
bash $B/looks/frames360.sh presets/portra800.json NAME    # 360-line stills of IMG_0607/0610/0613/0616
$V $B/looks/refmeasure.py "$B/looks/hald/Kodak Portra 800 2.png" NAME   # L p5/p50/p95, grey a/b, skin/foliage/sky/red C and hue
rm luts/film/NAME.cube                                    # unless it replaces the stock's cube
```
Bake variants in parallel (one output name each); `frames360.sh` shares a work dir, so run it serially.
Super 8: `trim.py IN OUT CHROMA CONTRAST [PIVOT [CAST_A CAST_B [RED_ROT BLUE_SAT [SKY_ROT [GREEN_SAT]]]]]`
on a Kodachrome base from `bake2.py OUT kodak_kodachrome_64 kodak_2383 '<the TITLE's JSON>'`, then the same `reencode-for-apple-display.py` step.
`looks/tune.sh` and `tune_s8.sh` chain these from the repo root, via `${TMPDIR:-/tmp}/ffgrade-tune/`; `tune_s8.sh` reads the Kodachrome base from there as `k_b.cube`.
**Never skip `reencode-for-apple-display.py`:** the bake scripts write gamma 2.4, every committed cube is Apple playback
(`display=apple`). Proof the chain first: rebaking the committed TITLE's params and running
`reencode-for-apple-display.py ... luts/film/portra160.cube` as COMPARE prints max diff 0.0 (checked 2026-09-21: the shipped Portra 160 came from this route; route A has not landed yet).

## Scorecard (route A, in `calib.py`)

Classes: green, red ivy, brick, blue, grey dark/mid/bright, saturated. Pass per class **and per scene**:
|ΔL| < 0.02, |ΔC| < max(0.003, 10% of target C), |Δhue| < 5° (skipped below target C 0.015).
Sky and ground: matched as distributions (lightness quantiles, median a/b per lightness band, b within
0.004), because clouds move and the road is off the facade plane. Detail: a grey ramp stays monotone
and keeps ≥ 80% of the stock cube's highlight slope; black and white points printed. A round passes
only when every line passes. Log it (change → result) in the research README, copy the raw output
to `scorecards/roundN.txt`, back up `calib.py` and its `.npy` as `_roundN` before the next change.

## The user's look rules (from his corrections)

- **No clipping or crushed ends for effect.** "Real film captures more detail in shadows and
  highlights": curves pinned 0→0 and 1→1 with a minimum slope, the detail check above, and
  out-of-gamut colour loses chroma at constant hue instead of clipping. A lower mean error bought
  with lost separation is a regression.
- **Protect blue, sky and green.** Fits on few blue pixels grey the signs and windows ("look at the
  absence of blue"); free hue terms turned foliage orange ("the plants look like it's autumn").
  Every class weighs the same, hue terms are regularised toward zero and fade at high chroma, and
  nothing is written in hue angle near grey (atan2 jumps, contour lines). Check the sign, window, sky
  and ivy crops every round.
- **It should be mechanical.** With registered pairs, the scorecard judges; don't ask him to judge
  what numbers can. Show him only a round that passes, with one metric and one sheet.
- **Speed.** Render once, cache, iterate offline; fits in the background and in parallel (one per
  variant, own log file); cap samples (≤ 800 patches per clip) before waiting on a slow fit. One model,
  one metric per step, no serial foreground trial-and-error.
- **Fit to patch means, never raw pixels:** misregistered pairs pull every colour toward its
  neighbours' average (chroma collapse to near greyscale).
- **Tone only before the stock cube** (one shared curve): the stock is not monotone off the grey axis.
- **Per-clip exposure is fitted, not baked**; the look's exposure is `match.reference_stops`.

## Judging by eye

Use the `look-sheet` skill (`scripts/look-sheet.sh`, `-r` for the scans) for comparison sheets, never a
hand-built one: it gets the display colour wrong. Judge definition on an export (`-d`), not a still: the
scan resolves more.

## Landing it

- Cube → `luts/film/<stock>.cube`; its TITLE records every parameter (`fit=partner-scans:<hash>`
  for route A). Keep each line under 500 chars: ffmpeg reads cube lines into a 512-char buffer;
  longer parameter dumps go on `#` lines (`Cube3D.swift` skips them).
- `presets/<look>.json`: `match.reference_stops`, grain, halation, and the `_comment` saying what it
  is now matched to. Neutral is not here: `look.json` + `scripts/make-rendering-lut.py`.
- `luts/film/CHANGELOG.txt`: what was modified (the licence asks for it).
- Remove the finished `docs/BACKLOG.md` entry in the same PR; run `./scripts/check.sh` in the
  background. Rebuild `dist/LogGrade.app` in the main checkout after merging.
