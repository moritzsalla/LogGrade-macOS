# The exposure reference can come from the shoot, not from one frame of one clip

`grade.sh` solves each clip's gamma so its post-CST luma mean lands on `match.reference_yavg`
(609). That number was measured on one frame of one clip of one shoot, so for anyone else's footage
it is meaningless, yet it still moves every clip. `MATCH=batch` anchors on the median of the run's
own clips instead. `MATCH=0` turns matching off.

`reference_yavg` is a measurement of a frame wearing a look value's clothes. The rest of
`look.json` is preference and travels; this does not.

## The default is open

`MATCH=1` is still the default. It was kept to preserve byte-identity with the precursor, a reason
ADR 0014 withdrew. Whether `batch` should become the default is undecided.

## Consequences

- **The lower median on an even count.** A real clip's measurement is reproducible regardless of
  list order; an average of two is a number no clip has.
- **Measured once, used by position.** The batch pre-pass probes every clip, and the render loop
  reads results by index. An index that did not advance past a skipped clip would hand every later
  clip the previous clip's exposure: a wrong grade on a file that looks finished. The test for this
  once passed against a removed guard, because its skipped clip was too short to measure.
- **One probe function (`probe_yavg`), two callers.** Two copies are how the `metadata=print`
  INFO-level bug would return.
- **`matched` is compared numerically.** `solve-gamma.py` prints `2.020` where `look.json` says
  `2.02`.
- **An unmeasurable batch is refused** (`REFUSE_BATCH_NO_PROBE`), not silently given `look.json`'s
  value.
- On the reference shoot the batch median was 609.7, which is where 609 came from.
