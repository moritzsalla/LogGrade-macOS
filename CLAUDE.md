# CLAUDE.md

The traps, and where things live. `CONTEXT.md` defines the words (*look* ≠ *tone* ≠ *grade*).

## Check

```sh
./scripts/check.sh          # before a commit: shellcheck, grade golden, swift-format, Swift, render golden, bats
./scripts/check.sh --fast   # while iterating; not a pass for a commit
```

- A missing tool fails the run; `--allow-skips` accepts a partial one on purpose.
- shellcheck and bats catch different bugs. macOS runs **bash 3.2**, whose empty arrays under `set -u` differ from modern bash. Run both.
- Tag a bats test that renders footage or builds the app `slow`, and one that writes outside `$BATS_TEST_TMPDIR` `serial` (top of `tests/lib.bats`). Wait for a condition, never a duration.
- `tests/render-golden.sh` holds the default image. If a change is meant to move it, compare the renders in `dist/golden/` and run `--regenerate "<why>"`. Never regenerate just to go green. `--conformance` only reports whether the default still matches the precursor (ADR 0014).

## Filter traps

All silent. Measurements are in `docs/PIPELINE.md` or beside the builder in `scripts/lib.sh`.

- `eq` silently drops the chain to 8-bit. Check every new filter with `-v debug | grep picking`.
- `lut1d` and `colorbalance` cannot take a YUV plane; ffmpeg converts to RGB around them (ADR 0003).
- `colorlevels` gives a flat frame here; use `curves`, and measure its spline rather than trusting the control points.
- Only `zscale` dithers 10→8 bit.
- Tag synthesised branches and `mergeplanes` output with `setparams`, or a `zscale` upstream fails.
- Grain goes after the sharpener, at half resolution.
- `blend` needs `shortest=1` (see `DELIVERY_BLEND`).
- In float, `blend` addition, `avgblur` and `boxblur` clamp at 1.0, and `lut1d` ignores a negative `DOMAIN_MIN` (ADR 0012).
- Verify colour tags after every encode (`safe_retag`); encoders ignore the flags.

## ffprobe misreports this camera's files

- The video stream prints twice.
- `-select_streams a:0` returns nothing.
- csv output ends in a trailing comma.

Query one field at a time with `-of default=nw=1:nk=1`, and validate the answer with a regex (`lib.sh`).

## bats and shell traps

- A bare `[[ ]]` mid-test never fails it. End each one in `|| fail "..."`.
- `run` disables errexit. Test abort and cleanup behaviour in a subshell that sources `lib.sh`.
- `pipefail` is on: `grep -qv` reports 141, and `$(ls glob | head -1)` fails on no match.
- A refusal test asserts the refusal's own words, and that the work was not attempted.
- A grep guard needs a word boundary, and must not match prose.
- Mutation-test a new guard: confirm the mutation applied, and run only the covering test against it.
- The filter graph needs a real render (`PROOF=<seconds>`). Camera quirks need real footage from `src/`, skipping when it is absent.
- Test interpolation on something that is not smooth.
- Measure timing in release or not at all. Two renders at one timecode share a path.
- A test that cannot fail is worse than none.

## Code rules

- Look values live only in `look.json`. `look()` has no fallbacks: a missing key stops the run.
- Unset ≠ empty: a loader keeps a set `SAT` or `HUE_LUT`, even empty; only an unset one reads `look.json`.
- Generated cubes are fresh by content (the `TITLE` stamp), never by mtime.
- The grade chain, the delivery chain, encode flags, stage paths and generator flags are spelled once, in `lib.sh`. A test fails on a copy.
- Take a generator's verdict first: `state="$(correction_state)" || exit 1`.
- Never point `ffmpeg -y` at a delivery path; use `render_delivery`.
- Never re-grade from a delivered MP4. A lost master is regenerated from the source.
- No rotation logic in the pipeline. Orientation is measured from a decoded frame (ADR 0005). Media layout is ADR 0006.
- The app builds release by default (`make-app.sh --debug` for debug). Debug makes the live preview about 100× slower.
- The live preview (`LiveChain`) runs the whole chain in-process, and `LiveChainTests` holds it to the render (ADR 0009).
- A second implementation of the image (`CorrectionCube`, `ToneCurve`) needs an exact-equivalence test against the generator it replaced, not a tolerance.
- When deleting a concept, grep for its name in prose too.

## Open questions

These were "settled", and the user has reopened them.

- The look: the Portra LUT is not the reference, the partner's analog scans are. The off-spec saturation and "tone, not colour" were judged on one shoot's road signs.
- The tests feel too heavy: keep the silent-failure guards, thin out the rest.

## Doc rules

- Docs are notes for Claude, not humans. `README.md` is the exception, the storefront: never edit it for agent notes.
- Each fact gets one home, ideally a comment beside the code it protects. Elsewhere, only a pointer.
- Keep a note only if it prevents a measured mistake or explains why the code is shaped that way.
- No one-shoot stories, and no history git already has.
- Delete a reversed decision, keeping any still-true measurement as one line.
- Where things are: `USAGE.md` (knobs, codes), `docs/PIPELINE.md` (findings, rejected approaches), `docs/APP_DESIGN.md`, `docs/adr/`, `docs/BACKLOG.md`, `PROVENANCE.md` (the fork point).

## Style

Tabs in shell scripts. Comments say why, briefly.
