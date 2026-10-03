---
name: look-match
description: Change, tune or re-bake a film look (Portra 160, Portra 800, Super 8, any stock cube in luts/film/) toward target images — the partner's analog scans and edits, public scans or RawTherapee Hald CLUTs. Use whenever the user says a preset or look is too warm/cool/dark/flat/saturated, skin looks off, it "doesn't look like her photos / the scans", asks to match, calibrate, fit, tune or rerun the match, mentions the partner's scans, references/, spektrafilm, film emulation or stock matching, or ~/Documents/ffgrade-film-bake. Also covers where the bake toolchain lives and how a cube lands in the repo.
---

# Look match

The goal is a look that reads roughly like the partner would edit it, in one click — not a pixel
match to two photos. The user's words: "maximum result with minimum effort". On 2026-10-02 nine
rounds of constrained refitting nearly made him abandon the project; the look that shipped (#107) is
the simple one below. Start there, and stay there unless a look-sheet shows a specific failure.

Licence: spektrafilm is GPLv3 and the cubes CC BY-SA, so the toolchain lives outside git and every
cube change is logged in `luts/film/CHANGELOG.txt`. The partner's scans are never committed:
`references/` and `docs/research/` are in `.git/info/exclude`.

## The model: stock + her edit + a few global numbers

```
cube(log) = her_edit( stock(log) ) with Oklab chroma x s          (luts/film/portra160.cube)
density   = the preset's match.reference_stops                    (presets/portra160.json)
warmth    = the preset's correct.temp / correct.tint, if ever needed
```

- **stock**: the uncalibrated spektrafilm cube, `git show b4255cd:luts/film/portra160.cube`
  (TITLE `display=apple`). It renders skin correctly on its own; it agrees with RawTherapee's Portra 160.
- **her edit**: three per-channel curves measured scan → edit on the SAME pixels of her two frames
  (`references/Ivy0N.png` vs `Ivy edit, 0N.png`), so no registration. Gentle: shadows ~1/4 stop darker,
  cooler, ×0.75 chroma. Build with bin MEANS (the scans are 8-bit; medians make 1/255 plateaus that
  flatten highlights), half the average slope at least, and unit slope above scan code 0.9 (no pixels
  there; extrapolating gave a 0.96 white).
- **global numbers**: fitted on the registered facade patches, or set by eye. Every one applies to every
  colour alike, which is why skin cannot drift away from walls. Shipped: s = 0.62, reference_stops −1.0.

A user complaint maps to one number: too saturated/dull → s; too dark/light → reference_stops; too
warm/cool → correct.temp; Portra 800 → re-derive (below). Change one, render one sheet, ship.

## Doing it

Scripts are in the main checkout's `docs/research/portra160-skin/` (local only; read its README first):

```sh
V=~/Documents/ffgrade-film-bake/venv/bin/python   # the only Python with spektrafilm, numpy, scipy, skimage
cd docs/research/portra160-skin
$V editcurve.py          # her edit curves -> edit_curves.npy (only if the curve rules change)
$V simple.py fit         # fits density and s on the facade -> simple_p.npy; prints both and the error
$V simple.py bake        # writes luts/film/portra160.cube + portra800.cube in the MAIN checkout
```

To set s by hand instead of fitting, edit `simple_p.npy` (`[density, s]`) before `bake`. `bake` already
encodes for Adobe-RGB light (`from=adobergb-power`) and derives Portra 800 (Oklab lightness contrast 0.9
about 0.6, black +0.02, chroma 0.9), so no re-encode step follows. Copy the cubes into a worktree if you
work in one. Density goes in both presets' `reference_stops` by hand (the fit prints it in stops).

## Judging and landing

1. `look-sheet` skill: faces (`~/Movies/Mexico Sample shots/IMG_0201, 0346, 0484`) and the facade with
   references (`-r`, `~/Movies/Nina facade plants prores shots/IMG_0609, 0618`), shipped vs new. Shipped
   comes from a temporary `git worktree add --detach <scratch>/shipped HEAD` as `-c shipped=<path>:portra160`.
2. Skin check, numbers rather than eyes: `$V simple.py skin` prints median skin L, C, hue for the stock,
   RawTherapee and the current `simple_p.npy`. The test is HUE: within ~8° of stock/RawTherapee (39–61°
   shipped), never toward magenta. Chroma and lightness follow s and density on purpose (shipped: lit skin
   C 0.053 vs stock 0.073, shaded faces L ~0.20), so judge those on the sheet, not against the stock.
3. `luts/film/CHANGELOG.txt` entry, preset `_comment`, then the PR. A cube/preset-only change is the
   `look` scope of `check.sh` (no parity renders, golden kept). Rebuild `dist/LogGrade.app` after merging.

Per `looks-target-the-scans`, a measured move toward her look ships without asking; show the sheet.

## What not to do again (measured 2026-10-02, details in that README)

- **No per-class or per-pixel correction fitted to the two frames.** Two facade scenes are about three
  colours; any flexible model (free matrix, hue polynomial, chroma curve, trust-weighted terms) reaches
  a low facade error by overfitting, and the overfit is what reaches skin. Round 11 (0.0073 Oklab) halved
  lit-skin chroma, turned reds magenta and crushed shaded faces. Free 3×3 matrices collapsed (green built
  from blue) whenever they were left in.
- **No tone that only some colours get.** Exposure moved into colour-local terms renders a wall and a face
  of one brightness differently. Tone is the stock, her curve and reference_stops, nothing else.
- **The scenes disagree.** At metered exposure scene A wants more brick chroma, scene B less; no transform
  satisfies both. Don't chase the per-class scorecard to green.
- **Cross-scene holdout cannot pass** (no shared colours); hold out a clip of the same scene instead.
- **Ask before a second round.** If one global-number change and its sheet don't settle it, stop and show
  the user what's left rather than iterating.

## Super 8 and other stocks with only public references

Tune stock parameters, not a correction: the parameters are the JSON in the cube's TITLE.

```sh
B=~/Documents/ffgrade-film-bake; V=$B/venv/bin/python   # from the repo root; ~80 s per bake
$V $B/scan_bake3.py $S/NAME.cube kodak_portra_800 '{...}' 2>&1 | grep -v Warning | tail -1
python3 .claude/skills/look-match/reencode-for-apple-display.py $S/NAME.cube luts/film/NAME.cube scripts
bash $B/looks/frames360.sh look.json neutral              # once: Neutral stills the Hald is applied to
bash $B/looks/frames360.sh presets/portra800.json NAME    # stills of IMG_0607/0610/0613/0616
$V $B/looks/refmeasure.py "$B/looks/hald/Kodak Portra 800 2.png" NAME   # L, grey a/b, skin/foliage/sky/red
```

Super 8: `trim.py IN OUT CHROMA CONTRAST [PIVOT [CAST_A CAST_B [RED_ROT BLUE_SAT [SKY_ROT [GREEN_SAT]]]]]`
on a Kodachrome base from `bake2.py OUT kodak_kodachrome_64 kodak_2383 '<TITLE JSON>'`, then the same
re-encode. **Never skip `reencode-for-apple-display.py`** for these: the bake scripts write gamma 2.4 and
committed cubes are Apple playback (`display=apple1.961`). Bake variants in parallel, one output name each;
`frames360.sh` shares a work dir, so run it serially. Neutral is not a film look: it is
`scripts/make-rendering-lut.py` (contrast/saturation flags; the TITLE holds the parameters).

## Traps that still hold

- Sheets: use the `look-sheet` skill, never a hand-built one; plain ffmpeg tiles show Apple-playback codes
  as sRGB, ~9/255 too dark, and drop the scans' Adobe RGB.
- Cube TITLE lines stay under 500 chars (ffmpeg's 512-char line buffer); long parameter dumps go on `#` lines.
- Footage: IMG_0624's sky is clipped in the source. Run long bakes and renders in the background.
