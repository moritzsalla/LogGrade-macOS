# A deliverable is data, not a case branch

Two shapes were written into the pipeline: 9:16 at 1080x1920 and 4:5 at 1080x1350, as a two-arm
`case` in `03-final.sh` and as `REELS_W`/`FEED_H`/`FEED_W` arithmetic plus a `FEED` boolean in
`grade.sh`. Adding a third meant editing both. A deliverable is now a record — a name, an aspect,
and an optional crop offset — resolved by `deliverable_spec` in `lib.sh`, and the set is whatever
`DELIVERABLES` says it is. Instagram's two survive as presets rather than as the only options.

The pipeline was built for one shoot delivered to one platform, and that was the right scope while
it was true. It stopped being true, and the cost of the old shape was not that it was small: it was
that the platform's assumptions were spread across a size, an aspect, a boolean, an output name and
a crop window, with nothing naming them as one decision.

## Width is the anchor, not height

Every deliverable is the same portrait master scaled to the same horizontal resolution. The
platform re-encodes to a fixed width, so two deliverables differing in width would be re-encoded
differently for no reason anyone chose. `WIDTH` therefore anchors the set and each height follows
from that deliverable's own aspect.

That is also why the existing numbers fall out rather than needing to be preserved by hand: 1080
wide is 1920 at 9:16 and 1350 at 4:5, which is exactly what the two branches hardcoded. `HEIGHT` is
kept as the knob it was — the 9:16 reference frame — and `WIDTH` defaults to its 9:16 width, so a
run that says nothing renders what it always did.

**The cost, stated because it is real:** a `HEIGHT` that is not a multiple of 16 lands a 9:16 frame
a pixel or two off the number asked for, since the width it derives is rounded to even first. Each
deliverable's resolved size is printed per clip. A rounding that is said out loud is a rounding; the
same rounding in silence is this project's oldest failure class.

## Consequences

- **`crop_prefix` returns empty for a deliverable that is already the source's shape**, and this is
  what keeps the default render byte-identical. Every deliverable resolves its crop through that
  one function now, where the 9:16 one used to be handed a literal empty string by its own branch.
  A no-op `crop=2160:3840:0:0` renders the same picture and still changes the graph, which is a
  difference `tests/conformance.sh` sees. Verified: byte-identical, 631813 bytes.
- **Whether a deliverable crops is a fact about the source, not about its name.** 4:5 is a crop of
  a 9:16 master and the whole frame of a 4:5 one. `deliverable_crops` answers that from a measured
  frame, and the refusal that uses it checks every clip in the run rather than the first — the
  first clip is exactly the one that might be about to be skipped, which would decide the run on a
  frame it never renders.
- **The refusal generalised with it.** `REFUSE_FEED_NO_CROP_Y` is now `REFUSE_CROP_NO_OFFSET` and
  names which deliverable wanted an offset. The reasoning did not change: a crop offset is a
  composition call, and one clip's framing applied to eighteen others produces files that all look
  done. Only the set it applies to changed.
- **A source that is not the deliverable's aspect is now CROPPED to reach it, not scaled into it.**
  That is a behaviour change on any source that is not exactly 9:16, and it is the correct one —
  the old path quietly changed the picture's aspect, which is CONTEXT.md's *squashed* failure. The
  camera's own 2160x3840 is exactly 9:16, so nothing about real footage moves. It surfaced because
  the suite's synthetic fixtures were 64x128, i.e. 1:2, and had been silently stretched for as long
  as they had existed; they are 72x128 now, which is the shape they always claimed to be.
- **The crop offset has no default, and centre was refused as one.** It was 750 — IMG_0609's
  composition, correct for exactly one clip in the world — and opening the deliverable set up
  pointed it at every shape rather than at one. Centre is the obvious replacement and is the wrong
  one: the README's own list of what took longest says a batch centred by default gives files that
  all look finished and are all framed wrong. So the default is gone rather than substituted, a
  cropping deliverable is refused without an offset for one clip as readily as for twenty, and
  `CROP_Y=centre` reaches the same picture as a decision somebody made. It is resolved per clip
  against the measured frame, which is the thing a fixed pixel offset cannot be, and the row it
  lands on is printed. The app never depended on the default: it already blocks a render whose
  cropping deliverable has no per-clip offset, so this makes the engine agree with it rather than
  the reverse.
- **Deliverable names reach a filename and an ffmpeg argument**, so they go through
  `require_clip_name` rather than a weaker guard written beside them.
- **What is NOT built:** two-dimensional crop geometry. The window is still as wide as the source,
  with only a vertical offset, in both the engine and the app. A landscape deliverable is therefore
  a horizontal band of the master and cannot be panned sideways. That is a separate decision with
  its own cost, deliberately left to one.
- **The app offers the presets, not an editor.** `Deliverable.presets` generates the interface, so
  a new preset costs no UI work; an arbitrary shape is carried by the project file and the engine
  but is not yet something the interface can author.
- **Untuned above and below 1080x1920.** The sharpener's radius follows the output height and its
  amount does not, and the grain was sized at 1080 — an assumption, never a measurement, at any
  other size. Opening the set up makes that reachable where before it took a deliberate `HEIGHT`.
  `delivery_image_chain` says which of the two numbers has evidence behind it. Measuring it is
  outstanding work, not a thing this decision settles.
