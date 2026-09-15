# Orientation is an ingest concern, not a grading one

The pipeline carries no rotation logic; the source is trusted to play the right way up, as in an NLE.
iPhone ProRes stores rotation as a QuickTime display-matrix flag, and ffmpeg autorotates on decode.
A manual `transpose` therefore double-rotates: two attempts both produced garbage. Re-encoding to fix
orientation also costs a generation of quality, while Preview and QuickTime fix the matrix
losslessly.

## Consequences

- **Orientation is measured from the decoded frame, never the metadata or the container.** The
  container says 3840x2160 for a clip that decodes 2160x3840. Any orientation is accepted and cropped
  to the deliverable's shape, never scaled into it (*squashed*). The app learns the size from
  `clip_planned`.
- **It fails closed.** A clip whose frame cannot be measured is skipped (`REFUSE_UNMEASURED`). The
  old portrait guard once accepted everything when its probe returned nothing, because an empty
  dimension made the comparison error and the `if` read that as false.
- **A portrait shot stored on its side renders sideways.** Nothing refuses it; the preview shows it.
- **Look at a frame before reasoning about metadata.** Eleven clips arrived with no rotation matrix,
  portrait content lying on its side, and were misdiagnosed as landscape for hours. One rendered
  frame would have settled it.
- **When a concept is deleted, grep for its name in prose too.** Removing rotation in pieces left a
  runbook step telling you to pass an argument that was silently ignored.
