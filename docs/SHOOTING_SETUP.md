# How to shoot, so the grading works

Read once. Takes about five minutes to set up, and you only do it once — the phone remembers.

If the footage isn't shot this way, the automatic grading will produce something wrong-looking,
and no amount of processing afterwards fixes it.

---

## The one-time setup

You need the **Final Cut Camera** app (free, from Apple). The normal Camera app can't record in
the format this needs.

In Final Cut Camera, set:

| Setting | Set it to | Why, in one line |
|---|---|---|
| **Format** | **ProRes** (not HEVC/H.264) | Keeps far more picture information for grading. |
| **Colour** | **Apple Log** | The flat, grey-looking one. This is the point — see below. |
| **Resolution** | **4K** | Room to crop and stabilise without losing sharpness. |
| **Frame rate** | **24 fps** | The frame rate films use. 30 or 60 looks like TV. |

Then, before you record:

- **Lock focus** — tap and hold on your subject until it says AE/AF LOCK.
- **Lock white balance** — same idea. Locked, not automatic.

That's it. Those six things.

---

## "It looks grey and washed out on my phone"

That's correct. Don't fix it.

**Apple Log** deliberately records a flat, low-contrast image. It looks wrong on purpose, because
it's keeping information in the very bright and very dark parts that a normal-looking recording
would throw away. The grading puts the contrast and colour back, with far more to work with.

A normal iPhone video has already had contrast, colour and sharpening baked in by the phone —
permanently. Log hands those decisions to us instead.

So: if it looks flat and boring on the phone, it's working.

---

## Hold the phone vertically

**Shoot vertical if you want Reels or Stories.**

This matters more than it sounds. Roughly half the clips on the first shoot were filmed
horizontally, and there is no good automatic way to turn a horizontal shot into a vertical one —
about two-thirds of the picture has to be thrown away. The pipeline refuses those clips rather than
quietly ruining them, so they simply won't get processed.

If a shot really wants to be horizontal, that's fine — just know it's a different deliverable and
won't come out of the vertical batch.

**Leave a little space top and bottom** if the shot might also be used as a square-ish feed post —
that crop cuts the top and bottom off. Nothing essential in the top or bottom sixth.

---

## Two things worth doing on the day

**Put something with a known colour in one shot per location.** A parked car's yellow numberplate,
a red or blue road sign. These have legally fixed colours, which lets the grading be checked
against something real instead of guessed at. It costs ten seconds and it's the single most useful
thing you can do for the result. A grey card, or any known-neutral surface, in one frame per setup
does the same for white balance: it turns a judgement into a measurement.

**If you want that warm golden-hour glow, lock white balance while pointing somewhere shaded.**

This one is counter-intuitive. Locking white balance normally makes the camera *cancel out*
whatever colour the light is — including the lovely warm light near sunset. The footage comes back
looking neutral, and the warmth has to be added back in afterwards.

Locking it while pointed at shade tells the phone the light is cooler than it is, so the warm light
survives into the recording.

Either way is fine — just know which one you're choosing.

---

## Exposure

Let the bright parts be bright, and don't worry if the picture looks a bit dark.

Log protects highlights well. Pulling a too-bright picture down later works; recovering a blown-out
white sky doesn't. If in doubt, err darker.

---

## Getting the clips onto the Mac

Final Cut Camera keeps its recordings **inside the app**, not in Photos. So plugging the phone in
and opening Photos or Image Capture will show **nothing**, and it will look like the transfer
failed. It hasn't.

Instead: open **Final Cut Camera → Library → select clips → Share → AirDrop** to the Mac. They'll
land in Downloads.

(If you're using a cable and the phone doesn't appear at all, try a different cable — many are
charge-only and carry no data, with no indication of it.)

---

## Then what

Drop the folder of clips onto the grading app. It does the rest and tells you what it did —
including which clips it skipped and why.

## Quick checklist

- [ ] Final Cut Camera app
- [ ] ProRes
- [ ] Apple Log
- [ ] 4K
- [ ] 24 fps
- [ ] Focus locked
- [ ] White balance locked
- [ ] Phone held vertically
- [ ] Something with a known colour in one shot

---

## What the first shoot measured

Everything above is a rule. This is the evidence for it, from grading the 11 Sept shoot, and none
of it was fixable afterwards — which is what makes the five minutes of setup worth it.

**ProRes 422 HQ + Apple Log at 4K24 was the right call.** Log carries linear values up to 12×
diffuse white, roughly 3.6 stops of headroom above white, and this shoot used about 5.4× of it.
That headroom is the raw material the grade shapes; a normal Rec.709 capture throws it away in the
phone.

**Locking white balance cost the golden hour.** IMG_0609 was shot at 20:02 local, about twenty
minutes before sunset. The footage does not look like it, and that is the lock working exactly as
designed: it compensates the scene to neutral, cancelling the warm light along with any cast.
Measured, the road — a true neutral reference — read R174 G176 B177, very slightly *cool*, in warm
evening light. The result is colorimetrically correct and the grade can put warmth back, but it was
a choice being made without realising it. Locked rather than auto is still right either way,
because it keeps every clip in the shoot consistent and one grade then transfers across all of
them. Auto would drift shot to shot and each clip would need its own correction.

**Mixed orientation broke the batch.** The shoot came back three ways:

| Rotation matrix | Clips | Presents as |
|---|---|---|
| none | IMG_0607, 0608, 0610–0618 (11) | 3840×2160 **landscape** |
| −90° | IMG_0619–0625 (7) | 2160×3840 portrait |
| +90° | IMG_0609 (1) | 2160×3840 portrait |

Eleven clips could not go to 9:16 without discarding roughly two-thirds of the frame width. The
pipeline refuses those now; before it did, one was silently squashed into a vertical frame and
produced convincing-looking garbage. The full episode is in
`docs/adr/0005_ORIENTATION_IS_AN_INGEST_CONCERN.md`.

**Erring darker worked.** The brightest areas peaked at YMAX 854 of 1023 in the source, comfortably
unclipped, which left room to shape. Keep doing that.

**The standardised colours did the most work of anything on this list.** A Dutch licence plate
(RAL 1021), a traffic-red 30 ring (RAL 3020) and a traffic-blue parking sign (RAL 5017) all
happened to be in shot, and they became the entire calibration basis for the grade — see
`docs/PIPELINE.md`. They also disproved several confident-but-wrong judgements made by eye. In a
location without signage, shoot one frame with something of known colour in it.
