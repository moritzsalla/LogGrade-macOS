# Vocabulary

One meaning per word. Where a file or variable uses a ruled-out word, this file is right and the name
is wrong.

**Capture assumptions:** Final Cut Camera, ProRes, Apple Log, 4K, 24 fps, focus and white balance
locked.

## Material

**Clip**: one camera recording, named by its iPhone filename stem (`IMG_0609`) at every stage.
_Avoid_: shot, take, file

**Source**: the untouched recording. Read-only. _Avoid_: original, raw, master

**Baseline**: a clip after the conversion and colour tags, nothing else. _Avoid_: neutral

**Master**: a clip's graded ProRes, the only file a re-export starts from. _Avoid_: final, graded master

**Intermediates**: a clip's baseline and master, on disk only while the clip is worked on.
_Avoid_: cache, "the masters"

**Deliverable**: a named shape (name, aspect, optional crop offset) resolved by `deliverable_spec`.
Presets: Reels/Stories 9:16 and Feed 4:5; any `name:w:h` works (ADR 0010). A shape, not a size.
_Avoid_: format, cut, version

**Final**: the delivered H.264 for one clip in one deliverable. _Avoid_: export, `<clip>_final`

**Proof**: a cheap, undelivered render through the whole delivery chain, made to decide something.
_Avoid_: draft, test render

**Preview**: the still the app shows while a control moves. It covers the grade only (correction,
halation, conversion, look, print, hue curves, tone, trims), not grain, sharpening, denoise, stabilisation or dither.
A proof answers "is this deliverable"; a preview answers "is this the grade".

## The grade

**Conversion**: what `convert.cube` names — the app's own rendering of Apple Log
(`luts/rendering/neutral.cube`), or a film cube from `luts/film/` that renders a stock's negative and
scan in its place. Either takes the log picture to the display in one scene-referred step. Apple's
own cube was the third option until it was dropped. _Avoid_: CST, "the Apple LUT"

**Film preset**: a complete look file in `presets/` built on a film conversion. _Avoid_: film look
(that is the Look stage)

**Look**: the film-emulation LUT: colour character, almost no contrast. _Avoid_: preset, style, grade

**Halation**: the warm glow past bright edges, added in linear light before the conversion.
_Avoid_: bloom

**Print**: the print-film LUT (Kodak 2383 and kin), after the look and before the tone, with a
strength. _Avoid_: second look, output LUT

**Hue curves**: per-colour hue, saturation and lightness, twelve knots on Oklab hue, after the print
and before the tone (`make-hue-lut.py`). Distinct from the trims' global saturation.

**Tone**: the generated luma curve that gives density. _Avoid_: S-curve, tone map, grade

**Correction**: the input stage: exposure, white balance and wheels, applied in Apple Log before
the conversion, and what each clip's metering is added to. Left out of the graph when neutral.
_Avoid_: colour correction, input LUT

**Grade**: correction + halation + look + print + hue curves + tone + trims: the whole creative transform.
_Avoid_: look, edit

**Colour correction**: moving colour toward its measured spec. Not the correction stage.

**Filmic route**: the abandoned log → linear → filmic tone map → Rec.709 approach
(`make-filmic-lut.py`). It lost on colour to Apple's cube, having no gamut handling; the renderings
that replaced that cube carry one. "Tone map" belongs to it.

## Measurement

**Reference**: an object in frame with a standardised colour (plate yellow, traffic red and blue).
It says where the image is, not where it should go. _Avoid_: target, chart

**Spec**: the published value a reference is read against. _Avoid_: target, ground truth

**Sampler**: a probe placed over a reference. **Patch**: the region it averages.
**Reading**: what it measures.

**Golden**: an output this repo recorded from its own engine. A change that moves it fails by name
until someone re-records it with a reason. It says what the engine did, not whether that was good.
Grade golden: ffmpeg's output per patch. Render golden: the default image. _Avoid_: oracle, snapshot

**Precursor**: `ffgrade`, frozen at the fork point. Provenance, not a standard (ADR 0014).
_Avoid_: reference, oracle, upstream

## Failures, by name

**Flat**: correct colour, no tonal density. A grading problem. _Avoid_: washed out

**Bleached**: Rec.709 pixels with a BT.2020 tag, transformed twice by a player. A tagging bug.

**Neon**: a per-channel contrast curve making saturated signage glow. Why the tone is luma-only.

**Squashed**: a clip scaled into another shape with no warning. A wrong aspect is cropped, never
stretched (ADR 0010). _Avoid_: stretched

**Engine**: `scripts/`, the LUTs and `look.json`. It owns the image; the app sets variables, spawns it
and reads its events, and never builds a filter graph. _Avoid_: backend

**Grading session**: one sitting over one clip, ending in a grade saved to `look.json`.
