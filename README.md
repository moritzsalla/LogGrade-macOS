# LogGrade-macOS

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

```sh
./app/make-app.sh        # builds dist/LogGrade.app
```

Build it optimised: the preview grades every frame with the whole chain, and a debug build is
unusable. H.264 exports render on the GPU where they can, about 1.5 times faster than the ffmpeg
engine they are tested against, which renders everything else. → [`USAGE.md`](USAGE.md) for the controls and the CLI underneath.

---

## The preview is the render

Most grading tools approximate while you drag and render when you stop. This one grades every
picture, dragged or settled, with the whole chain, and tests hold it to the exported render. There
is no preview button and no slower "exact" render replacing it.

→ [`adr/0009`](docs/adr/0009_THE_PREVIEW_STAYS_EXACT_UNTIL_THE_DIVERGENCE_IS_EXPLAINED.md)

![Tone ladder](docs/grade-ladder-tone.png)

---

## Scope and licence

macOS 13 or later. Nothing to download: the app renders Apple Log with its own conversion. It builds
as one universal bundle for Intel and Apple silicon, developed on Intel and not yet verified on
Apple silicon.

[PolyForm Noncommercial 1.0.0](LICENSE). Run it, change it, share it, keep the attribution.
Commercial use needs permission. The film stocks in `luts/film/` are baked from spektrafilm and
keep its terms (`luts/film/SPEKTRAFILM_LICENSE.txt`).
