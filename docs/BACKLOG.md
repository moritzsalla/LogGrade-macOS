# Backlog

Open work only. Finished work lives in git.

**The point of the app:** give iPhone Apple Log footage an incredible look, very easily. Today it
takes lots of input and still doesn't look good. Judge entries by that, and by whether a
non-technical photographer could use the result.

## Next, in order

1. **The look, judged against the partner's analog scans**, not the Portra LUT (a coarse community
   emulation). Needs scans and iPhone clips of similar scenes. Measure tone, colour and grain against
   them, and the user judges by eye. The default image may move (`render-golden.sh --regenerate`).
   This includes the unsigned v4 look and the grain strength (8, never judged by eye). The film
   presets (`presets/`) were tuned by eye on 3–4 frames of one overcast shoot: judge the Portra and
   400H scans, the 65mm look, and each preset's grain and halation against real references too.
2. **Verify the universal app on the Apple silicon Mac** (built in #10). Launch shows Kind: Apple for
   LogGrade and ffmpeg; one render with stabilisation; how far it differs from this Mac's render
   (arm64 ffmpeg is OSXExperts 9.0, x86 is evermeet 9.0.1); jq 1.8.2 (minos 14) runs if that Mac is
   on macOS 13. `docs/UNIVERSAL_APP_PLAN.md`.

## The app, as it feels to use

- **Export is slow on the Intel Mac.** Measure where the time goes first.

## Open work

- **Local adjustments** (a sky or a face held separately). Global grading uses Apple Log's latitude
  only across the whole frame. A product decision before a design: what a non-technical user draws.
- **Judge sharpen and grain at other heights by eye.** Measured (`docs/PIPELINE.md`, sheets in
  `dist/measure-sizes/`). Grain stays ~1 output px, so it is 1.7× coarser relative to the picture at
  960 than at 1920.
- **Rename "look" where it means the whole grade.** `look.json`, `grade.sh` and `LOOK_FILE` say look;
  CONTEXT.md defines look as the film LUT. Built into file and variable names, so a rename.
- **Audio:** a separate ambience recording for street detail handheld capture misses.
- **Optional: tighten the parity ceilings.** A dry-run remeasure found seven loose by 0.1–0.9 code
  values and `extreme` 0.25 above its ceiling (inside the margin).
  `tests/grade-parity.py --remeasure "<why>"`.
- **Defaults kept only for the precursor's sake** (ADR 0014): the stabiliser's `unsharp=5:5:0.2`.
- **Judge the shipped rendering against a reference.** `luts/rendering/neutral.cube` (contrast 1.6,
  saturation 1.1) was tuned by eye on one overcast shoot, and confirmed by the user on IMG_0609 once
  it displayed on Apple playback's curve. Not yet judged on a sunny, contrasty scene. Its tone scale
  and gamut compression are published maths, but where it sits between them is a judgement.

## Considered and declined

- **The filmic route.** It lost on colour (`docs/PIPELINE.md`).
- **A native render in AVFoundation.** ADR 0008.
- **Python linting.** Run `ruff` once if it bothers you.
