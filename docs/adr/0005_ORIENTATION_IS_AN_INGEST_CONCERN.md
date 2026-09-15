# Orientation is an ingest concern, not a grading one

The pipeline carries no rotation logic; the source is trusted to play the right way up, as in an NLE.
iPhone ProRes stores rotation as a QuickTime display-matrix flag, and ffmpeg autorotates on decode.
A manual `transpose` therefore double-rotates: two attempts both produced garbage. Re-encoding to fix
orientation also costs a generation of quality, while Preview and QuickTime fix the matrix
losslessly.

## Consequences

- **The guard measures the decoded frame, never the metadata or the container.** The container says
  3840x2160 for a clip that decodes 2160x3840. The danger is a clip silently scaled into another
  shape (*squashed*).
- **It fails closed.** It once shipped accepting everything when its probe returned nothing, because
  an empty dimension made the comparison error and the `if` read that as false. A guard that cannot
  measure must refuse.
- **Look at a frame before reasoning about metadata.** Eleven clips arrived with no rotation matrix,
  portrait content lying on its side, and were misdiagnosed as landscape for hours. One rendered
  frame would have settled it.
- **When a concept is deleted, grep for its name in prose too.** Removing rotation in pieces left a
  runbook step telling you to pass an argument that was silently ignored.
