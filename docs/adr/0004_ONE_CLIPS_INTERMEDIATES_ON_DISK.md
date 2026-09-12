# Keep one clip's ProRes intermediates on disk at a time

Keeping every clip's ProRes intermediates at once does not fit on this machine; the arithmetic is
in `docs/PIPELINE.md` under "Disk space policy", which is where the measurements for this decision
live. Policy: a clip's intermediates live only while that clip is being worked on — review,
proofs, sign-off — and are deleted once it is approved. The finals and the untouched source are
the only things kept per clip long-term.

## Considered options

**Delete immediately after each export** was rejected deliberately. Regenerating a master is a
ten-minute-plus wait, so deleting it the moment finals exist turns any later "nudge the curve
slightly" into that wait before you can see anything. Holding it through the sign-off loop costs
nothing extra — it is still one clip's worth of disk — and keeps iteration fast where iteration
happens.

## Consequences

Re-grading a finished clip means regenerating its baseline and master from source through the
stage scripts first. That is cheap in disk and costs render time only, which is the right way
round. It is also why nothing downstream may ever re-grade from a delivered MP4.
