# ffgrade-macOS

One stop grading tool for iPhone ProRes + AppleLog footage. **This is a personal use tool, not a
product.**

![LogGrade](docs/app.png)

**Why?** iPhone Pros from the 15th generation on shoot in log, which retains enough depth to edit
professionally — dynamic range, shadow detail and 10-bit colour, good enough to sit alongside
footage from professional cinema cameras. Log holds real highlight headroom and none of the HDR
tone mapping or sharpening a normal phone capture bakes in.

Getting that out of it requires an understanding of colour spaces, LUTs and exposure, and usually
professional software. This tool gets about as much image quality out of iPhone footage as the
format actually holds, without opening an NLE. Pick a look (Neutral, or a film stock: Portra 160,
Portra 800, Super 8) and the footage comes out finished.

**Why not an existing app?** Log files are ordinary video, so any app opens them, but they look
flat and grey until they are converted and graded. The free tool that does that properly is
DaVinci Resolve, a full professional suite. Final Cut Pro converts Apple Log, but it is a paid
editor and the look is still yours to build. Editors that accept LUTs expect you to bring one. None
of them is quick: footage in, a good look, a file out.

**How?** Each clip is metered, converted from Apple Log with its look, and exported to Rec.709 with
10-bit colour kept to delivery. Every clip keeps its own look and settings.

```sh
./app/make-app.sh        # builds dist/LogGrade.app
```

Build it optimised: the preview grades every frame with the whole chain, and a debug build is
unusable.

---

## The preview is the render

Most grading tools approximate while you drag and render when you stop. This one grades every
picture, dragged or settled, with the whole chain, and tests hold it to the exported render. There
is no preview button and no slower "exact" render replacing it.

→ [`adr/0009`](docs/adr/0009_THE_PREVIEW_STAYS_EXACT_UNTIL_THE_DIVERGENCE_IS_EXPLAINED.md)

![Tone ladder](docs/grade-ladder-tone.png)

---

## A film look is picked, not built

Each film look is a stock simulated from its datasheets (spektrafilm), rendered straight from the
log picture so the highlights keep their latitude. What reads as film beyond colour comes with it:

- **Halation** — the warm glow bright things spill past their edges, added in linear light before
  the conversion, where a sky and a white car are still different amounts of light.
- **Grain that follows the picture** — most in the midtones, receding into shadow and highlight,
  coarse for Portra 800 and heavy for Super 8.

You pick the stock; its halation and grain are not sliders. Each look is measured against
RawTherapee's free film emulations and straight scans of the real stock, then judged by eye on real
footage.

Exposure, warmth, tint, contrast and saturation act on the log picture before the look, so an
adjustment feeds the stock the way a different exposure or light would, instead of bending its
finished colour.

**A shoot matches itself.** Clips shot across an evening land differently, so each is metered and
corrected in linear light before the look. The move is damped: a dusk clip stays darker than a noon
one, rather than every clip landing on one grey.

→ [`adr/0012`](docs/adr/0012_HALATION_IN_LINEAR_BEFORE_THE_CONVERSION.md)

---

## Deliver in any shape

The app exports a vertical story (9:16), a 4:5 post, or Custom: one aspect (16:9, 4:3, 1:1, 4:5,
9:16) at a short edge from 720p to 2160p. Sharpening and grain scale with the size, so every export
gets what was judged at 1080. The crop is placed per clip, and export names every clip nobody
framed.

On the command line the set is open:

```sh
DELIVERABLES=reels,feed ./scripts/grade.sh src/            # story and post
DELIVERABLES=square:1:1,wide:16:9:400 ./scripts/grade.sh src/IMG_0609.mov
```

→ [`adr/0010`](docs/adr/0010_A_DELIVERABLE_IS_DATA_NOT_A_CASE_BRANCH.md)

---

## Things that took the longest

- **Tone on luma only.** Curve all three channels and a contrast move turns saturated colour neon.
- **Grain at half resolution.** Platforms re-encode everything; full-resolution grain comes back as
  blobs.
- **Colour tags checked after every encode.** Encoders don't reliably write them, and a mistagged
  file looks bleached.
- **No silent centre crop.** Twelve clips cropped to centre by default are twelve files that look
  finished and are framed wrong.

---

## Layout

```
app/        Swift. GradeKit = models, the engine adapter and the in-process chain. LogGrade = the window.
scripts/    The engine. bash + ffmpeg. Start at lib.sh.
docs/       PIPELINE.md is the real documentation. adr/ holds the decisions.
look.json   The Neutral look. presets/ holds the film looks, in the same format.
tests/      Every test here exists because the thing it covers already broke.
```

The export is one ffmpeg pass. The app sets the engine's environment variables and reads its
events, and never builds a filter graph itself; the preview is the same chain rebuilt in Swift.
`./scripts/check.sh` runs every test.

→ [`USAGE.md`](USAGE.md) for the controls and the CLI underneath.

---

## Scope and licence

macOS 13 or later. Nothing to download: the app renders Apple Log with its own conversion. It builds
as one universal bundle for Intel and Apple silicon, developed on Intel and not yet verified on
Apple silicon.

[PolyForm Noncommercial 1.0.0](LICENSE). Run it, change it, share it, keep the attribution.
Commercial use needs permission. The film stocks in `luts/film/` are baked from spektrafilm and
keep its terms (`luts/film/SPEKTRAFILM_LICENSE.txt`).
