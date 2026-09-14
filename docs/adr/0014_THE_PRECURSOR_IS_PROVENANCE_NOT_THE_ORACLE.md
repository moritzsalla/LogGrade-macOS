# The precursor is provenance, not the oracle

`tests/conformance.sh` asserted that this fork's default render was byte-identical to the frozen
precursor's. It was built to prove that a copy survived being instrumented and then parameterised,
and it did prove that. Over time it became something else: the standard every change to the default
image was judged against. ADR 0011 called it "the oracle the whole fork rests on".

But the precursor is as good as the edit could be made at the time, not as good as it could be. A
render that has to match it can never improve on it.

## What that cost, concretely

- **The look numbers were never frozen.** Both engines read this repo's `look.json`, so the value of
  any key the precursor already knew could change freely.
- **The chain and the generators were frozen.** This covers the downscale, sharpener, grain, dither
  and encode. The precursor also runs its own `make-tone-lut.py`, so even a better tone curve changed
  one side only. Two of those settings are marked in `lib.sh` as inherited and never measured: the
  exposure probe's `-ss 1` and `scale=320:-1`, and the stabiliser's `unsharp`. Improving them was
  forbidden by construction.
- **Every new stage was forced to default off.** Halation, the print stage, the input correction and
  weighted grain all have to be *absent* at their neutral values. Otherwise the default render stops
  being the precursor's, so the out-of-the-box image can never gain anything the old edit lacked.
- **It decided at least one question on the wrong grounds.** ADR 0011 describes `reference_yavg` as
  a measurement of one afternoon wearing a look value's clothes. It kept it as the default anyway,
  because "a decision that costs [conformance] is not worth the tidiness".
- **It could not be re-based.** Its own header said that a change which legitimately breaks it
  should "re-base the expectation deliberately". The expectation was a live render of a repo nobody
  may touch, so there was nothing to re-base. The only options were to leave the default where it
  was forever or to delete the guard. A guard you have to delete in order to make progress will
  eventually be deleted, and then nothing guards the image.

## The decision

The default image is held by `tests/render-golden.sh` against `tests/fixtures/render-golden.json`,
recorded from this repo's own render. It keeps what mattered about conformance: one real clip goes
through the real chain, and the comparison is byte for byte, on a packet-stream hash. What it adds
is a legitimate way to move:

- `--regenerate "<why>"` records the new image, and refuses without a reason. The reason is written
  into the golden, so the diff that moves the image also carries the justification.
- A mismatch lists which inputs differ from when the golden was recorded. That separates "you changed
  `lib.sh`" from "nothing you changed, yet the image moved".
- Every render is kept in `dist/golden/` named by its hash, so the old and new images can be compared
  by eye. **The hash says the image changed, not that it got better.** Whether it got better is
  judged the way the tone was: by eye, and by measurement against the references in frame.

The golden was seeded from a render whose stream hash matched the precursor's on the same build,
`243b504b…`. The expectation therefore starts exactly where conformance left it.

`tests/conformance.sh` stays, opt-in and informational. A difference now exits 4, which `check.sh`
reports and does not fail on: it answers whether the default has departed from the precursor yet,
not whether it may. A render that fails is still a failure.

## Consequences

- **"Absent at neutral" still holds, for its own reasons.** An idle float round trip moves the
  picture by 0.23 code values on average (ADR 0012), and an identity cube adds interpolation error on
  every pixel. A neutral stage stays out of the graph because of those measurements, not to match
  another repo. The comments that gave the precursor as the reason now give the measurement.
- **A stage may now be on by default.** That is a change to the default image, made through
  `--regenerate` with a reason. It is still a decision, and nothing here makes one.
- **ADR 0011's default is a merits question again.** Whether `MATCH=1` should stay the default is
  open. This record does not answer it.
- **The golden is tied to one ffmpeg build and one architecture.** Conformance was immune to this,
  because both sides ran the same binary. The encoder writes its version into the stream, and SIMD
  paths are not promised to agree, so a golden from another build is a *skip*, which `check.sh`
  counts against the run. Recording on the second Mac would flip which machine skips. If that
  becomes a real cost, measure whether the two builds actually differ before loosening the check.
- **It costs one render, about 11 seconds,** in the full `check.sh`. `--fast` leaves it out, along
  with the other renders.
- **The precursor stays frozen and read-only.** It is where this repo came from, recorded in
  `PROVENANCE.md`, and it is still useful for asking what the old edit did. It is no longer an answer
  to what the image should be.
