# Grading pipeline — 11 Sep house shoot

The vocabulary this project uses for turning one shoot's iPhone ProRes / Apple Log recordings into
Instagram deliverables. Several of these words were being used for two things at once during
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
A named delivery format at a fixed frame size. Two exist: **Reels/Stories** (9:16) and **Feed**
(4:5).
_Avoid_: format, aspect, cut, version, crop

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
the grade only — CST, look, tone, trims — and cannot show grain, the sharpener, the chroma
denoise, the stabiliser or the dither, all of which are delivery-stage. The word was previously
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

**Tone**:
The generated luma curve that gives the image density and separation. The half of the grade that
actually makes it read as graded.
_Avoid_: contrast curve, S-curve, tone map (reserved for the filmic route), grade

**Grade**:
Look plus tone plus the saturation and warmth trims — the whole creative transform, and what a
grading session decides.
_Avoid_: look, edit, post, colour correction

**Colour correction**:
Moving colour toward its measured spec. Named here only because this project has none: every
correction tried moved a reference off spec.
_Avoid_: using it loosely as a synonym for grade

**Variant**:
One generated candidate tone LUT in a sweep, named series-and-step (`t_a`, `w_b`).
_Avoid_: version, option, test

**Ladder**:
One image holding the same frame through several variants side by side, to pick one by eye.
_Avoid_: grid, strip, steps, contact sheet

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
A probe placed over a reference in the Bench. Its position is per-shoot: a plate or a sign is
wherever it is.
_Avoid_: picker, eyedropper, probe, point

**Patch**:
The pixel region a reading is actually averaged over.
_Avoid_: crop, region, area, sample

**Reading**:
What a sampler measures at the current settings, in that reference's own unit.
_Avoid_: value, result, measurement

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
A landscape clip scaled into a vertical frame with no error and no warning. The batch failure
that produces files which all look done.
_Avoid_: stretched, wrong aspect

**Engine**:
The shell pipeline: `scripts/`, the LUTs and `look.json`. It owns the image. An interface sets its
environment variables, spawns it and reads its events; it never builds a filter graph itself.
_Avoid_: backend, core, the scripts

## Working

**Grade Bench** (the Bench):
The browser tool where the grade is decided by eye, with every reference read live beside the
picture.
_Avoid_: grader — in this trade a grader is a person; also workbench, the tool, the artifact

**Grading session**:
One sitting at the Bench over one clip's frames, ending in a grade sent back.
_Avoid_: round trip, review

**Rotation class**: _retired._
Meant which of the three display-matrix values a clip carried (none, −90, +90). The pipeline no
longer reasons about display matrices at all — it decodes a frame and measures it — so the term
has no code behind it. See ADR 0005. Kept here only so the phrase is recognisable in old notes.
