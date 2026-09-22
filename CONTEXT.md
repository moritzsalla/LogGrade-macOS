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

**Export preset**: Instagram Story, Instagram Post, or Custom: the delivery settings picked in the
app. The two Instagram ones fix every field. _Avoid_: deliverable (that is the shape)

**Final**: the delivered file for one clip in one deliverable. _Avoid_: export, `<clip>_final`

**Proof**: a cheap, undelivered render through the whole delivery chain, made to decide something.
_Avoid_: draft, test render

**Preview**: the still the app shows while a control moves. It covers the grade only (correction,
halation, conversion), not grain, sharpening, denoise, stabilisation or dither.
A proof answers "is this deliverable"; a preview answers "is this the grade".

## The grade

**Conversion**: what `convert.cube` names — the app's own rendering of Apple Log
(`luts/rendering/neutral.cube`), or a film cube from `luts/film/` that renders a stock's negative and
scan in its place. Either takes the log picture to the display in one scene-referred step. Apple's
own cube was the third option until it was dropped. _Avoid_: CST, "the Apple LUT"

**Look**: one complete look file, picked once per batch: Neutral (`look.json`) or a film stock in
`presets/`. Fixed; a person only switches its grain. _Avoid_: preset (ambiguous with export preset),
style

**Adjust**: a clip's own moves on top of the look (exposure, warmth, tint, contrast, saturation,
match), stored per clip in the project. _Avoid_: override, grade

**Halation**: the warm glow past bright edges, added in linear light before the conversion.
_Avoid_: bloom

**Correction**: the input stage: exposure, white balance, contrast and saturation, applied in Apple
Log before the conversion, and what each clip's metering and Adjust are added to. Left out of the graph when neutral.
_Avoid_: colour correction, input LUT

**Grade**: correction + halation + conversion: the whole transform a
look and a clip's Adjust produce. _Avoid_: edit

**Colour correction**: moving colour toward its measured spec. Not the correction stage.

## Measurement

**Reference**: an object in frame with a standardised colour (plate yellow, traffic red and blue).
It says where the image is, not where it should go. _Avoid_: target, chart

**Spec**: the published value a reference is read against. _Avoid_: target, ground truth

**Sampler**: a probe placed over a reference. **Patch**: the region it averages.
**Reading**: what it measures.

**Golden**: an output this repo recorded from its own engine. A change that moves it fails by name
until someone re-records it with a reason. It says what the engine did, not whether that was good.
Render golden: the default image. _Avoid_: oracle, snapshot

**Precursor**: `ffgrade`, frozen at the fork point. Provenance, not a standard.
_Avoid_: reference, oracle, upstream

## Failures, by name

**Flat**: correct colour, no tonal density. A grading problem. _Avoid_: washed out

**Bleached**: Rec.709 pixels with a BT.2020 tag, transformed twice by a player. A tagging bug.

**Neon**: a per-channel contrast curve making saturated signage glow.

**Squashed**: a clip scaled into another shape with no warning. A wrong aspect is cropped, never
stretched (ADR 0010). _Avoid_: stretched

**Engine**: `scripts/`, the LUTs and `look.json`. It owns the image; the app sets variables, spawns it
and reads its events, and never builds a filter graph. _Avoid_: backend

**Native export**: an export rendered in the app on the GPU instead of by the engine, for the
deliverables it can take, held to the engine's file. _Avoid_: fast export, GPU render

**Grading session**: one sitting over a shoot: a look picked, clips adjusted and framed, saved as a
project.
