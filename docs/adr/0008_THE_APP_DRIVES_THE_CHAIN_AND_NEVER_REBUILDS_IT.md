# The app drives the shell chain and never rebuilds it

The title records the original decision, since reversed in stages. The preview grades in-process
(ADR 0009). An H.264 export the native path can take (`NativeExport.unsupported` says which) renders
in-process on the GPU; everything else spawns `scripts/grade.sh` and reads its event stream, and
never builds a filter graph. grade.sh stays the reference: the native export is held to its file by
`ExportParityTests`, and any native failure falls back to it (`RenderQueue.runNatively`).

## What made rebuilding it hard, and how the native export answers it

- **AVFoundation colour-matches every pixel** from the source colour space to the destination (per
  Apple's technote). With Apple Log in BT.2020 going to Rec.709, that adds an invisible transform on
  top of the LUT: the *bleached* failure, arriving through the framework. The native export reads the
  decoder's planes with no colour space and tags every encoder buffer 709 by hand.
- **VideoToolbox H.264 has no constant-rate factor.** Grain survival was measured against x264 CRF
  18, so the native export's bitrate is set to deliver the same grain (`ExportParityTests`), at about
  twice the file size.
- **The chain is the residue of measured failures:** a spline that overshoots, a filter that
  silently goes 8-bit, an untagged branch poisoning a converter upstream, grain rung by the
  sharpener. The native export transcribes the chain's decisions rather than rediscovering them, and
  each transcription has its own test against the original.

## Consequences

- **A second implementation of the render is measured against grade.sh** (`LiveChainTests`,
  `ExportParityTests`), never trusted on sight.
- **Enforced by a test.** `EndToEndTests` renders one clip from the shell and from the app and
  asserts identical bytes. Same binary, same arguments, so any difference means the app built its
  own graph.
- **The engine must be legible to a program.** Hence the event stream, the named codes, and stdout
  carrying one format.
