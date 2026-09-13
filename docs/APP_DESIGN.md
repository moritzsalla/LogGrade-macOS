# The app's visual design

Written before the interface was built, kept because the reasons outlast the pixels. `bench/`'s
own header makes the same argument for its dark theme; this is that argument applied to a window
with three columns in it.

## Subject
A measuring instrument that happens to make pictures. One person, his own street footage,
judging an image and adjusting it. Lineage: a darkroom enlarger and a light meter, not a SaaS
dashboard. The interface's job is to stay out of the way of a photograph and to make its own
numbers readable.

## Color — achromatic surround, one measured accent
    surround   #191919   the room. Neutral, not tinted: any cast in the chrome biases the
                         judgement, which is why grading suites are grey.
    panel      #202020   where controls live
    well       #0E0E0E   a recess for the image, darker than the room so the picture sits in it
    hairline   #2E2E2E   structure, never decoration
    ink        #E8E8E8 / #9A9A9A / #6E6E6E
    plate      #F3C300   RAL 1021, the plate yellow this pipeline MEASURES against. The one
                         accent, reused from the Bench, because a tool's accent should be a
                         colour it knows the value of.
    lamp       #E06A4B   refusals only. A signal lamp, not a web error.
No green anywhere: "ready" is the absence of a warning, and a green tick next to a photograph is
two colours competing with it.

## Type
SF Pro Text for labels — on this platform the native face is the correct choice, not a default.
Every measured value is SF Mono with tabular figures, so a column of numbers can be scanned and
compared. That is the instrument move: readouts align, labels recede. Sentence case throughout,
matching the repo's own voice. No all-caps eyebrows.

## Layout — the chain is a spine
    ┌──────────────┬────────────────────────┬──────────────────────────┐
    │ clips        │                        │ ● Apple Log → Rec.709 🔒 │
    │ ┌──┐ IMG_0607│      ┌──────────┐      │ │                        │
    │ │▓▓│ Apple Log│      │          │      │ ○ correct                │
    │ └──┘          │      │  image   │      │ │   exposure   ▭──  0.00 │
    │ ┌──┐ IMG_0608│      │          │      │ ○ look                   │
    │ │▓▓│         │      └──────────┘      │ │   kodak_portra_400_nc  │
    │ └──┘          │   preview  compare     │ ○ tone         ╱ curve   │
    │              │   grade only            │ ┊ delivery (not shown)   │
    └──────────────┴────────────────────────┴──────────────────────────┘
A hairline rail runs down the inspector with a dot per stage: filled for the locked conversion,
open for editable stages, dotted below the preview boundary for stages a still cannot show. The
order of the chain is drawn as a line, because the order IS the grade. Left-aligned everywhere;
numbers right-aligned against the rail's far edge.

## Principles
1. The photograph is the only saturated thing on screen.
2. Structure encodes the chain: the rail shows order, locking, and what the preview cannot show.
3. Readouts are instrument-grade: monospaced, tabular, editable by typing as well as dragging.
4. The picture follows the control. Every one of them, including the corrections that run before
   Apple's conversion — a grading control you cannot see the effect of while you move it is a
   control you cannot find a value with. The preview is live while a control is moving and exact
   once it lands.
5. The preview always says which of the three it is showing: live, exact, or stale. An instrument
   that shows a stale reading is lying, and one that passes an approximation off as the render is
   lying in a way that is harder to catch.
6. Spend the boldness on the rail. Everything else is quiet greys and one yellow.

## What the first build got wrong, and what it cost

Four things, all found by looking at a screenshot rather than by reasoning:

- **Every slider track was the accent colour.** One yellow track is a highlight; ten are a second
  subject competing with the photograph. The accent is now spent on three things only: the locked
  stage's dot, the selected clip's edge, and the curve.
- **The rail's line did not draw.** A `Rectangle` with a width and no height collapses, so the
  chain read as loose dots rather than an order. It fills the row now, which is the whole point of
  drawing it.
- **Every readout showed a decimal comma.** These values are written into `look.json`, which uses
  dots, so the panel disagreed with the file it produces. The formatter is POSIX.
- **The preview button was the brightest object on screen**, which in a tool for judging an image
  is the one thing it must never be.

## What the second build got wrong

One thing, and it was not found by looking at a screenshot. It was found by being asked.

**The preview did not follow the controls.** Every adjustment meant letting go of the slider and
waiting about three seconds for a render. A UX audit run over this interface listed seven gaps and
did not list that one — it named "superseded previews are not cancelled", which is a symptom of
render-on-release, while treating render-on-release itself as settled. The audit was run against
the reasoning already written down rather than against what the tool should feel like, and a
justification in a decision record is exactly the kind of thing an audit has to be willing to
question. The ADR that justified it had already been amended to say the obstacle was gone.

The fix is in `docs/adr/0009`. The check it suggests, for next time: for each control, say how long
it takes to see its effect, then ask whether anyone would use a control that costs that.

## What using it for real changed

Everything here came from grading actual clips rather than from reading the code.

**The interface had no scale.** Ten font sizes and fourteen spacings, each chosen one control at a
time. There are four type roles and five spacings now, on macOS's own metrics: 13 is the system
control size, 11 is what AppKit uses in inspectors, 10 is its caption. Weight carries the hierarchy
rather than size, which is what keeps a panel this dense readable.

**The panel explained itself at length, every visit.** Each stage carried a paragraph of prose. Read
once it is useful; read on every visit it is a wall between you and the sliders. It is behind a help
button now, in a popover, which is where macOS puts reference text. Stages collapse, and which ones
are open is remembered.

**There was no menu bar at all.** Not cosmetic: ⌘Q did not quit, and ⌘C, ⌘V and ⌘A did nothing in a
text field, because the standard editing commands reach a field by travelling up the responder chain
from a menu item. Shortcuts live there now, where macOS draws them beside the name. The one
exception is hold-to-compare, which a menu item cannot express.

**Disabled controls have to say why.** Convert can be blocked for four reasons and showed the same
grey rectangle for all of them, leaving guessing as the only move.

**Three bugs had one shape.** Thumbnails, the clip count behind Convert, and the drop target all
broke because state was copied into a second place and one of several callers forgot to keep it in
step. Each is now derived from the thing it describes, or funnelled through a single door. When a
fourth path appears it cannot forget, because there is nothing to remember.

**A busy indicator must not obscure the subject.** The picture greyed out to say "working", at
exactly the moment it was being judged. A spinner in the corner says the same thing.
