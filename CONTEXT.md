# Grading pipeline — vocabulary

The vocabulary this project uses for turning a shoot's iPhone ProRes / Apple Log recordings into
deliverables. It was first written for the 11 Sep house shoot; the terms are not specific to it. Several of these words were being used for two things at once during
development; the entries below pick one meaning each and name what was ruled out. Where a file,
folder or variable still carries a ruled-out word, this file is right and the name is wrong.

## Material

**Clip**:
One camera recording, identified by the iPhone filename stem it keeps at every stage
(`IMG_0609`). The join key back to `src/` and to the phone's own capture order.
_Avoid_: shot, take, file

**Source**:
The untouched camera recording as it came off the phone. Read-only for the life of the project.
_Avoid_: original, raw, footage, master

**Baseline**:
A clip after the CST and the colour tags, and nothing else — technically correct, with no creative
decision in it. No rotation: orientation is an ingest concern (ADR 0005).
_Avoid_: CST output, post-CST file, neutral, the flat pass

**Master**:
A clip's graded ProRes. The only file a re-export is allowed to start from.
_Avoid_: graded master (says it twice), final, the ProRes, the graded

**Intermediates**:
A clip's baseline and master together — the pair that exists on disk only while that clip is
being worked on.
_Avoid_: temp files, working files, cache, "the ProRes masters" (a baseline is not a master)

**Deliverable**:
A named shape to deliver in: a name, an aspect, and an optional crop offset, resolved by
`deliverable_spec`. Two ship as presets — **Reels/Stories** (9:16) and **Feed** (4:5) — and the set
is open: `DELIVERABLES` takes any `name:aspect-w:aspect-h`. It is a *shape*, not a size; the height
follows the aspect off the shared delivery width. See ADR 0010.
_Avoid_: format, aspect, cut, version, crop; also "the two deliverables", which was true and is not

**Final**:
The delivered H.264 file for one clip in one deliverable.
_Avoid_: export, render, delivery, `<clip>_final` — a final is named for its deliverable, not for
being finished

**Proof**:
A deliberately cheap, deliberately undelivered render made only to decide something. It goes
through the whole delivery chain, which is what makes it worth waiting for.
_Avoid_: draft, test render, sample

**Preview**:
The still the interface shows while a control moves. It is not a render and not a proof: it covers
the grade only — correction, halation, CST, look, print, tone, trims — and cannot show grain, the
sharpener, the chroma denoise, the stabiliser or the dither, all of which are delivery-stage. The word was previously
ruled out as a synonym for *proof*; it now has its own job and the two are not interchangeable.
A proof answers "is this deliverable"; a preview answers "is this the grade".
_Avoid_: using it for a proof, or for anything that has been through the delivery chain

## The grade

**CST**:
Apple's own Log→Rec.709 conversion — the transform, not its result. Treated as given: its colour
is more accurate than anything hand-rolled here.
_Avoid_: colour conversion, colour management, "the Apple LUT" (there are two)

**Look**:
The film-emulation LUT. It supplies colour character and almost no contrast.
_Avoid_: film LUT, creative LUT, preset, style, grade

**Halation**:
The warm glow a bright thing spills into the dark around it, added in linear light before the CST
and only past edges — a bright field does not glow onto itself. Its own stage, not part of the look.
_Avoid_: bloom, glow (as the stage's name), diffusion, highlight rolloff

**Print**:
The print-film emulation LUT (Kodak 2383 and kin) applied after the look and before the tone, the
way a negative is printed. Like the look it has a strength, which blends it back toward its input.
_Avoid_: calling it a second look, output LUT, film LUT

**Tone**:
The generated luma curve that gives the image density and separation. The half of the grade that
actually makes it read as graded.
_Avoid_: contrast curve, S-curve, tone map (reserved for the filmic route), grade

**Correction**:
The input stage: exposure, white balance and lift/gamma/gain wheels, applied in Apple Log before
the CST so it works on the whole of the source's headroom. A neutral correction is left out of the
graph entirely. It is a tool the grader reaches for, not a move toward spec.
_Avoid_: colour correction (see below), input LUT, pre-grade

**Grade**:
Correction plus halation plus look plus print plus tone plus the saturation and warmth trims — the
whole creative transform, and what a grading session decides.
_Avoid_: look, edit, post, colour correction

**Colour correction**:
Moving colour toward its measured spec. The shipped grade does none: every such move tried took a
reference off spec. Not the same thing as the **correction** stage, which exists and is creative.
_Avoid_: using it loosely as a synonym for grade, or for the correction stage

**Variant**: _retired._
Meant one generated candidate tone LUT in a sweep, named series-and-step (`t_a`, `w_b`). Nothing in
the engine or the app produces them any more. Kept here only so the phrase is recognisable in old
notes and in the ladder images the README and `docs/PIPELINE.md` still show.

**Ladder**: _retired._
Meant one image holding the same frame through several variants side by side, to pick one by eye.
Retired with **Variant**, for the same reason and with the same caveat.

**Filmic route**:
The abandoned approach that replaced the CST with log → scene-linear → filmic tone map →
Rec.709. Kept as a named dead end; "tone map" belongs to it, not to the shipped tone stage.
_Avoid_: Approach A, the scene-linear route, the from-scratch LUT

## Measurement

**Reference**:
An object in frame whose colour is legally standardised — the Dutch plate yellow, the traffic red
and the traffic blue — plus a known-neutral surface. It says where the image is, never where it
should go.
_Avoid_: target, chart, swatch, calibrator

**Spec**:
The published value a reference is read against, expressed as the ratio actually measured. The
shipped grade sits off spec on purpose.
_Avoid_: **target** — a spec is a place to measure from, not a number to hit; also correct value,
ground truth

**Sampler**:
A probe placed over a reference. Its position is per-shoot: a plate or a sign is wherever it is.
_Avoid_: picker, eyedropper, probe, point

**Patch**:
The pixel region a reading is actually averaged over.
_Avoid_: crop, region, area, sample

**Reading**:
What a sampler measures at the current settings, in that reference's own unit.
_Avoid_: value, result, measurement

**Golden**:
An output this repo recorded from its own engine, held so that a change which moves it fails by
name. It moves when someone records a new one with a reason. It says what the engine did, never
whether that was good. There are two: the grade golden (ffmpeg's output per probe patch, which
the preview is held to) and the render golden (the default image, byte for byte).
_Avoid_: oracle, expected, snapshot

**Precursor**:
`ffgrade`, frozen at the commit this repo forked from. Provenance: it records where the chain
came from and what the old edit did. It is not a standard the image is held to (ADR 0014).
_Avoid_: **reference** — that word is an object in frame; also oracle, original, upstream

## Failures, by name

**Flat**:
Correct colour with no tonal density — the image this pipeline exists to fix. A grading problem.
_Avoid_: milky, washed out, dull

**Bleached**:
A different fault entirely: correct Rec.709 pixels carrying a BT.2020 tag, so a tag-trusting
player transforms them a second time. A tagging bug, never a grading one.
_Avoid_: washed out, too bright — both hide the distinction from flat

**Neon**:
What a per-channel contrast curve does to an already-saturated object: it crushes the two low
channels harder than the high one, so signage glows. The reason the tone stage is luma-only.
_Avoid_: oversaturated, clipped

**Squashed**:
A clip scaled into a frame of another shape with no error and no warning. The batch failure that
produces files which all look done. `require_portrait` catches the landscape-into-vertical case;
since ADR 0010 a source that is merely the wrong aspect is cropped to the deliverable's shape
rather than stretched into it.
_Avoid_: stretched, wrong aspect

**Engine**:
The shell pipeline: `scripts/`, the LUTs and `look.json`. It owns the image. An interface sets its
environment variables, spawns it and reads its events; it never builds a filter graph itself.
_Avoid_: backend, core, the scripts

## Working

**Grade Bench** (the Bench): _retired._
The browser tool where the grade used to be decided by eye. The app replaced it and `bench/` was
deleted; the substance survived, since the grade is still judged against references in frame and
still leaves as `look.json`. See ADR 0007. Kept here only so the phrase is recognisable in old
notes — as with **Rotation class** below, this file is right and any surviving mention is wrong.

**Grading session**:
One sitting at the app over one clip's frames, ending in a grade saved to `look.json`.
_Avoid_: round trip, review

**Rotation class**: _retired._
Meant which of the three display-matrix values a clip carried (none, −90, +90). The pipeline no
longer reasons about display matrices at all — it decodes a frame and measures it — so the term
has no code behind it. See ADR 0005. Kept here only so the phrase is recognisable in old notes.
