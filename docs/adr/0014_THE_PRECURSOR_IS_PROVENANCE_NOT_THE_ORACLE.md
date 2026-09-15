# The precursor is provenance, not the oracle

`tests/conformance.sh` asserted that this fork's default render was byte-identical to the frozen
precursor's. That proved the fork survived being instrumented and parameterised. It then became the
standard every change to the default image was judged against. But the precursor was the best edit
at the time, not the best possible, and a render held to it can never improve.

## What that cost

- **Look values were free.** Both engines read this repo's `look.json`.
- **The chain and generators were frozen.** The downscale, sharpener, grain, dither and encode were
  fixed, and the precursor runs its own `make-tone-lut.py`, so a better curve changed one side only.
  Inherited settings never measured, such as the exposure probe's `-ss 1` / `scale=320:-1` and the
  stabiliser's `unsharp`, could not be improved.
- **Every new stage was forced to default off.**
- **ADR 0011 kept a default on those grounds** rather than on its merits.
- **It could not be re-based.** Its expectation was a live render of a repo nobody may touch, so
  the only ways past it were "never change" or "delete the guard".

## The decision

`tests/render-golden.sh` holds the default image against `tests/fixtures/render-golden.json`,
recorded from this repo. One real clip goes through the real chain, compared byte for byte on a
packet-stream hash. It can move on purpose:

- `--regenerate "<why>"` refuses without a reason and writes the reason into the golden.
- A mismatch lists which inputs changed since recording.
- Renders are kept in `dist/golden/` by hash, for comparison by eye. The hash says the image
  changed, not that it improved.

The golden was seeded from a render whose stream hash matched the precursor's (`243b504b…`).
`conformance.sh` stays opt-in and informational: a difference exits 4, which `check.sh` reports
without failing. A render that fails is still a failure.

## Consequences

- **Neutral stages stay absent for their own reasons:** the idle float round trip (ADR 0012) and
  identity-cube interpolation error.
- **A stage may now default on,** through `--regenerate` with a reason.
- **The golden is tied to one ffmpeg build and architecture.** Conformance was immune, because both
  sides ran one binary. The encoder writes its version into the stream, so a golden from another
  build is a skip, and `check.sh` counts that against the run. Measure whether two builds really
  differ before loosening this.
- **About 11 seconds per full `check.sh`;** `--fast` skips it.
