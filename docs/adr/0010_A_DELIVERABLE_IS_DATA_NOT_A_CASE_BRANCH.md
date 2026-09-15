# A deliverable is data, not a case branch

A deliverable is a record: a name, an aspect and an optional crop offset. `deliverable_spec` in
`lib.sh` resolves it, and the set is whatever `DELIVERABLES` says. Instagram's 9:16 and 4:5 are
presets, not the only options. They used to be a two-arm `case` in one script and ad-hoc arithmetic
in another, so adding a shape meant editing both.

## Width is the anchor

Every deliverable is scaled to the same width, and each height follows from its own aspect. The
platform re-encodes to a fixed width, so deliverables that differ in width get re-encoded
differently for no chosen reason. `HEIGHT` is the 9:16 reference and `WIDTH` defaults to its 9:16
width. A `HEIGHT` that is not a multiple of 16 lands a pixel or two off, and each resolved size is
printed per clip, because rounding in silence is this project's oldest failure class.

## Consequences

- **A deliverable already in the source's shape gets no crop filter.** A no-op `crop` renders the
  same picture but changes the graph, which the render golden sees.
- **Whether a deliverable crops is a fact about the source, not its name.** 4:5 is a crop of a 9:16
  master and the whole frame of a 4:5 one. `deliverable_crops` measures a decoded frame and checks
  every clip in the run, not just the first, since the first may be the one that gets skipped.
- **A source of the wrong aspect is cropped to the deliverable's shape, never scaled into it**
  (*squashed*). The test fixtures were silently stretched for as long as they were 1:2 instead of
  9:16.
- **The crop offset has no default, and centre is not one.** The old default of 750 was one clip's
  framing. A batch centred by default gives files that all look finished and are framed wrong. A
  cropping deliverable without an offset is refused (`REFUSE_CROP_NO_OFFSET`). `CROP_OFFSET=centre` is
  accepted as an explicit choice and resolved per clip against the measured frame.
- **Names reach a filename and an ffmpeg argument,** so they go through `require_clip_name`.
- **The crop window fills one source axis and moves along the other** (`crop_window`), so one offset
  is enough: vertical on a portrait source, horizontal on a landscape one.
- **Untuned away from 1080x1920.** The sharpener's radius follows output height but its amount
  does not, and the grain was sized at 1080. `delivery_image_chain` says which number has evidence
  behind it.
