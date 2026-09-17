# The app drives the shell chain and never rebuilds it

The title records the original decision, since reversed in stages. The preview grades in-process
(ADR 0009). Export still spawns `scripts/grade.sh` and reads its event stream, and never builds a
filter graph. A native export on the same in-process chain is being built and held to grade.sh by
`ExportParityTests`; grade.sh stays the source of truth until it is at parity.

## Why not rebuild it in Core Image and AVFoundation

- **AVFoundation colour-matches every pixel** from the source colour space to the destination (per
  Apple's technote). With Apple Log in BT.2020 going to Rec.709, that adds an invisible transform on
  top of the LUT: the *bleached* failure, arriving through the framework. Suppressing it means
  controlling every buffer's attachments by hand.
- **`h264_videotoolbox` has no constant-rate factor.** The shipped encode is `libx264 -crf 18
  -preset slow`, and grain survival through a platform re-encode was measured against it.
- **The chain is the residue of measured failures:** a spline that overshoots, a filter that
  silently goes 8-bit, an untagged branch poisoning a converter upstream, grain rung by the
  sharpener. None of that transfers; it would all be rediscovered.

## Consequences

- **A second implementation of the render is measured against grade.sh** (`LiveChainTests`,
  `ExportParityTests`), never trusted on sight.
- **Enforced by a test.** `EndToEndTests` renders one clip from the shell and from the app and
  asserts identical bytes. Same binary, same arguments, so any difference means the app built its
  own graph.
- **The engine must be legible to a program.** Hence the event stream, the named codes, and stdout
  carrying one format.
