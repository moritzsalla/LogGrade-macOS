# Orientation is an ingest concern, not a grading one

The pipeline used to carry rotation logic: stage 1 took a rotation argument, the docs told you to
check a preview frame and re-run with `180` if it came out sideways, and a "rotation class" was a
defined term. All of it is gone. The source is trusted to play the right way up, which is the same
assumption an NLE makes.

Two things forced it. iPhone ProRes carries rotation as a QuickTime display-matrix flag rather than
pixel-level rotation, and ffmpeg autorotates on decode — so a manual `transpose` fights the
auto-correction and double-rotates. Two attempts both produced landscape-looking garbage. And
correcting orientation by re-encoding costs a generation of quality to fix something Preview and
QuickTime both fix losslessly by rewriting the matrix.

So there is nothing to decide per clip, and a knob that only ever produces a worse result than
fixing the source is not a knob worth keeping.

## Consequences

- **One guard survives**, in the delivery stage: `require_portrait` decodes a frame and measures
  it, refusing anything that is not portrait. It measures the decoded frame rather than reading
  metadata, so it does not care whether orientation was corrected by re-encoding or by fixing the
  display matrix. The dangerous failure is a landscape master silently scaled into 1080x1920 — no
  error, just a squashed file that looks done — and that is what this refuses.
- **It must fail closed.** The guard shipped once in a state where an unreadable probe returned
  success, because an empty dimension makes the numeric comparison error and an `if` reads an
  erroring condition as false. A guard that cannot measure must refuse, not accept.
- **Removing a feature in pieces leaves lies behind.** The removal left stage 1's header promising
  a rotation fix, a pointer to a script that no longer existed, a runbook step telling you to pass
  an argument that was silently ignored, and a glossary term for a concept with no code. The
  runbook step was the dangerous one: you followed it, got a byte-identical file, and believed the
  rotation was fixed. When a concept is deleted, grep for its name everywhere, including prose.

Historical note worth keeping: this shoot arrived with 11 clips carrying **no rotation matrix at
all** — portrait content sitting in a 3840x2160 container, lying on its side. A sideways portrait
frame reads as a landscape composition in any file listing, so it was diagnosed as "landscape
footage needing a crop decision" and blocked the batch for hours. Rendering one frame would have
settled it immediately. When geometry looks strange, look at a picture before reasoning about
metadata.
