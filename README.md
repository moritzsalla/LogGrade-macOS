# ffgrade-macOS

One stop grading tool for iPhone ProRes + AppleLog footage. **This is a personal use tool, not a
product.**

![LogGrade](docs/app.png)

**Why?** iPhone Pros 15th generation and newer are able to shoot in log, which retains enough depth
to edit professionally — dynamic range, shadow detail and 10-bit colour, good enough to sit
alongside footage from professional cinema cameras.

Getting there requires an understanding of colour spaces, LUTs and exposure, and usually
professional software. This tool gets about as much image quality out of iPhone footage as the
format actually holds, without opening an NLE. Pick a look (Neutral, or a film stock: Portra 160,
Portra 800, Super 8) and the footage comes out finished.

**Why not an existing app?** Log files are ordinary video, so any app opens them, but they look
flat and grey until they are converted and graded. The free tool that does that properly is
DaVinci Resolve, a full professional suite. Final Cut Pro converts Apple Log, but it is a paid
editor and the look is still yours to build. Editors that accept LUTs expect you to bring one. None
of them is quick: footage in, a good look, a file out.

**How?** Apple Log → graded Rec.709. Export is one ffmpeg pass: 10-bit preserved to delivery, tone
curve applied to luma only, LUTs generated rather than guessed. The app sets that engine's
environment variables and reads its events, and never builds a filter graph itself. The preview is
the same chain rebuilt in Swift, graded in-process and tested against the engine's render. Each clip
keeps its own look and settings, and is exported on its own or with the rest.

**Does it work?** Very well. Log holds real highlight headroom above diffuse white and none of the
HDR tone mapping or sharpening a normal phone capture bakes in. Getting that out of it is a tone
problem, and tone is something ffmpeg can do properly.

```sh
./app/make-app.sh        # builds dist/LogGrade.app
./scripts/check.sh       # lint, parity, bats, Swift suite
```

Build it optimised — the live preview runs the real chain per frame and a debug build is unusable.

---

## The preview is the render

Most grading tools approximate while you drag and render when you stop. This one grades every
picture, dragged or settled, with the whole chain: the clip is decoded and metered in the app, then
put through the correction, halation, the film look, the hue curves and the tone curve in-process.
There is no preview button and no slower "exact" render replacing it.

That in-process chain is held to the engine's render by tests on real footage: against IMG_0607 at
the shipped look the mean difference is about 1.3 code values, with the worst pixels on hard edges,
where the preview resamples before grading and the render after. An earlier approximate GPU tier
was refused for the opposite reason: its error was worst on saturated colour and no one could say
why.

→ [`adr/0009`](docs/adr/0009_THE_PREVIEW_STAYS_EXACT_UNTIL_THE_DIVERGENCE_IS_EXPLAINED.md)

![Tone ladder](docs/grade-ladder-tone.png)

---

## The default image is recorded, and moves on purpose

The chain is a fork of an earlier CLI, frozen at one commit and never touched again. It used to be the
reference: the default render had to match it byte for byte. That proved the fork survived, and then
it stopped the image from ever getting better than the old edit.

```sh
./tests/render-golden.sh                        # is the default render the recorded one?
./tests/render-golden.sh --regenerate "<why>"   # it moved on purpose; record it, with the reason
```

A hash says the image changed, not that it improved. Both renders are kept in `dist/golden/` to judge
by eye.

→ [`PROVENANCE.md`](PROVENANCE.md)

---

## Four things that took the longest

**Tone on luma only.** Curve all three channels and a contrast move turns saturated colour neon.

**Grain at half resolution.** Social platforms re-encode everything; full-res grain comes back as
blobs. The plate is half resolution at a 1080 short edge and scales with the export's short edge,
so every size gets the grain that was judged.

**Verify the colour tags after every encode.** Encoders don't reliably write them, and Rec.709
pixels tagged BT.2020 get transformed a second time by anything that trusts the tag. It looks like
someone bleached the footage.

**The crop is placed per clip.** Default it to centre in silence and a batch of twelve gives you
twelve files that all look finished and are all framed wrong. The app renders an unplaced clip
centred and names every clip nobody framed; the command line refuses a crop without
`CROP_OFFSET`, and `CROP_OFFSET=centre` is how you say it out loud.

---

## A film look is picked, not built

Each film look is a stock simulated from its datasheets (spektrafilm), rendered straight from the
log picture so the highlights keep their latitude. What reads as film beyond colour comes with it:

- **Halation** — the warm glow bright things spill past their edges, added in linear light before
  the conversion, where a sky and a white car are still different amounts of light.
- **Grain that follows the picture** — most in the midtones, receding into shadow and highlight,
  coarse for Portra 800 and heavy for Super 8.

You pick the stock; its halation and grain are not sliders. Each look is measured against RawTherapee's
free film emulations (tone, and the hue and saturation of skin, foliage, sky and red) and against
straight scans of the real stock, and then judged by eye on real footage.

Exposure, warmth, tint, contrast and saturation act on the log picture before the look, so an
adjustment feeds the stock the way a different exposure or light would, instead of bending its
finished colour.

→ [`adr/0012`](docs/adr/0012_HALATION_IN_LINEAR_BEFORE_THE_CONVERSION.md)

---

## Deliver in any shape

A deliverable is a name, an aspect and a crop offset — not a size written into the pipeline. The app
offers a vertical story (9:16), a 4:5 post, and Custom: one aspect (16:9, 4:3, 1:1, 4:5, 9:16) at
a short edge from 720p to 2160p. On the command line the set is open:

```sh
DELIVERABLES=reels,feed ./scripts/grade.sh src/            # the two presets
DELIVERABLES=square:1:1,wide:16:9:400 ./scripts/grade.sh src/IMG_0609.mov
```

Height follows the aspect off one shared delivery width, because the platform re-encodes to a fixed
width and two deliverables that differed in it would be re-encoded differently for no reason. A
shape that is a crop of the master gets one, computed from the frame that is actually on disk; a
shape that is already the master's own gets no crop filter at all.

Sharpening and grain were tuned at a 1080 short edge and scale with it, so a 4K export gets the same
grain and sharpness against the picture as the size they were judged at.

→ [`adr/0010`](docs/adr/0010_A_DELIVERABLE_IS_DATA_NOT_A_CASE_BRANCH.md)

---

## Match a shoot to itself

Clips shot across an evening land differently, so each one is metered from a decoded frame — its
log-average brightness and how far its near-neutrals sit from grey — and corrected in linear light
before the conversion, where a stop is a stop. The move is damped: a dusk clip stays darker than a
noon one, rather than every clip landing on one grey.

```sh
MATCH=0 ./scripts/grade.sh src/     # render every clip as shot instead
```

---

## Layout

```
app/        Swift. GradeKit = models, the engine adapter and the in-process chain. LogGrade = the window.
scripts/    The engine. bash + ffmpeg. Start at lib.sh.
docs/       PIPELINE.md is the real documentation. adr/ holds the decisions.
look.json   The Neutral look. presets/ holds the film looks, in the same format.
tests/      Every test here exists because the thing it covers already broke.
```

→ [`USAGE.md`](USAGE.md) for the controls and the CLI underneath.

---

## Before it runs

Nothing to download: the app renders Apple Log with its own conversion.

## Scope and licence

macOS 13 or later, bash 3.2. The app builds as one universal bundle for Intel and Apple silicon;
it is developed on Intel and not yet verified on Apple silicon. Built for my footage and my
deliverables.

[PolyForm Noncommercial 1.0.0](LICENSE). Run it, change it, share it, keep the attribution.
Commercial use needs permission. The film stocks in `luts/film/` are baked from spektrafilm and
keep its terms (`luts/film/SPEKTRAFILM_LICENSE.txt`).
