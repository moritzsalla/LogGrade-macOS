# CLAUDE.md

Guidance for Claude Code working in this repo. `README.md` is the human orientation; this file
carries what an agent needs on top of it — the traps, and where the source of truth lives.

Read `docs/PIPELINE.md` before changing the render chain, and `CONTEXT.md` before writing anything
down. Several words here mean one specific thing: *look* is not *tone* is not *grade*, a *spec* is
what you measure against and depart from deliberately, and a *baseline* is not a *master*.

## Run this before trusting any change

```sh
./scripts/check.sh        # shellcheck, grade parity, the bats suite
```

A **missing tool now fails the run** rather than skipping quietly. This command used to exit 0
having run only bats, so "green" could mean "linted nothing and never compared the curves". Use
`--allow-skips` to accept a partial run on purpose. Don't write the test count down anywhere: it is
printed, and a number in prose goes stale by construction — the README said 20 while the suite said
42.

**shellcheck and bats are not substitutes for each other.** shellcheck reported ZERO issues in
scripts that contained two shipped, load-bearing bugs. bats found both, because it runs the code on
the real interpreter — macOS ships **bash 3.2**, whose handling of empty arrays under `set -u`
differs from every modern bash. Run both.

## Filter rules, and where the reason lives

Each was a silent failure — no error, just wrong output — and each is measured. The rule is here so
you don't trip it; the measurement is in `docs/PIPELINE.md`, which is the only place it belongs.

- **`eq` is banned.** It silently negotiates an 8-bit format, so the chain quietly stops being
  10-bit. Check any new filter with `-v debug | grep "picking yuv"`.
- **`lut1d` cannot take a YUV plane.** ffmpeg converts to `gbrp10le` around it, so the tone curve
  is applied per RGB channel and only its luma is merged back. The rule above about checking
  `-v debug | grep picking` is the one that catches this, and it was never run on `lut1d`. Run it
  on every filter, not only the ones already suspected.
- **`colorbalance` cannot either**, and its midtone window is not where its documentation suggests:
  measured on a ramp, it is zero below level 27, peaks at 0.70 around level 63, and is gone by 100.
  The shipped warmth of 0.005 therefore moves at most one code value, only in the shadows.
- **`colorlevels` produces a flat frame** on this input. Use `curves`.
- **Only `zscale` dithers** the 10→8 bit reduction. `format=yuv420p` and `-sws_dither ed` are
  byte-identical, i.e. neither does anything.
- **`curves` interpolates with a cubic spline.** Past ~3 uneven control points it overshoots
  somewhere you didn't intend. Measure the result, don't trust the control points.
- **Tag every synthesised branch with `setparams`.** An untagged `lavfi` source propagates
  "unknown" backwards and fails a `zscale` several filters upstream. `mergeplanes` output is
  untagged the same way.
- **Grain goes after the sharpener, at half resolution.** Before it, the sharpener rings it.
- **`blend` needs `shortest=1`;** `-shortest` is not a substitute under `filter_complex`. The
  reasoning is in `lib.sh`, above `DELIVERY_BLEND`.
- **Verify colour tags after every encode.** `prores_ks` and `libx264` both ignored the flags here,
  and a wrongly tagged file is double-transformed by any player that trusts it. `safe_retag`.

## ffprobe misreports this camera's files in three ways

All silent, all cost real time, all caused by a `[STREAM_GROUP]` structure ordinary idioms don't
expect. The measurements and the shipped bugs each one caused are in `docs/PIPELINE.md`.

1. **The video stream prints twice**, plus a blank line.
2. **`-select_streams a:0` returns nothing** despite audio being present. `-map 0:a:0?` for ffmpeg
   is a different code path and is unaffected.
3. **csv output carries a trailing comma** (`3840,2160,`), so a field split fails open. It appears
   on camera originals and `-c copy` excerpts of them, never on the pipeline's own re-encodes, so
   it hides until real footage reaches it.

Query one field at a time with `-of default=nw=1:nk=1` and validate with a regex. Never trust a
single-line ffprobe answer without checking what it actually printed.

## Testing rules

- **Never write a bare `[[ ... ]]` assertion.** In bats 1.14 a `[[ ]]` that returns false in the
  *middle* of a test body does not fail the test: `[[` is a shell keyword and the mechanism bats
  uses to spot a failure only tracks simple commands, so the verdict comes from the body's LAST
  command. `[` is a builtin and behaves as expected. Every `[[ ]]` in `tests/lib.bats` therefore
  ends in `|| fail "..."`, which is a function call and so is seen. This had already hidden a real
  defect: a test stayed green while the message it asserts on was renamed. Do not tidy the guard
  away.
- **bats `run` disables errexit, so it cannot see an abort.** bats turns errexit off around `run`
  in order to capture a status, which makes any behaviour that depends on `set -e` or `pipefail`
  invisible through it: a function that must return a verdict rather than abort, or a cleanup that
  must happen on the way out. Test those in a subshell that sources `lib.sh`, which is what
  production actually runs under. A `run`-based test stayed green against a `render_delivery` that
  aborted mid-pipeline and left its staging file behind.
- **`pipefail` makes several obvious assertions lie.** It is set by `lib.sh`, so it is in force in
  every test body that sources it. `grep -qv` closes the pipe on its first match and the writer
  dies of SIGPIPE, so the pipeline reports 141 regardless of the content; `x=$(ls glob | head -1)`
  fails the whole assignment when the glob matches nothing. Negate a positive match, or end the
  lookup in `|| true`.
- **A test whose subject is a refusal must assert the refusal's own words**, and that the work was
  not attempted. A synthetic fixture cannot complete the delivery chain — it fails reinitialising
  filters on the way to 1080x1920 — so `status != 0` and an empty output folder are true whether or
  not the guard fired. Three tests here passed against a removed guard for exactly that reason.
- **A grep guard needs a boundary and has to ignore prose.** `@Observable` is a prefix of
  `@ObservedObject`, so the obvious pattern flagged the correct spelling as the forbidden one —
  and once the boundary was added, the pattern matched the comment explaining the rule. A guard
  that cannot tell those apart is worse than none, because the fix it demands is wrong.
- **Mutation-test anything you add.** Break the guard, confirm the test goes red. Two tests here
  passed against a *removed* guard before this was done, and two more passed against a removed
  guard again afterwards for the `[[ ]]` reason above. Apply the mutation and *verify it applied* —
  a `perl -0pi -e` whose pattern silently fails to match proves nothing, and looked like a pass.
- **The production filter graph needs a real render.** shellcheck cannot see inside a filter
  string, the parity check touches only the tone curve, and a `DRY=1` run never builds the graph.
  `PROOF=<seconds>` renders through the identical chain, which is what the suite uses.
- **Synthetic fixtures cannot reproduce this camera's quirks.** A generated ProRes file prints one
  clean ffprobe line; a real clip prints three with a trailing comma. Tests covering those
  behaviours must use real footage from `src/` and skip when it is absent.
- **A second implementation of the image is licensed by an EXACT-equivalence test, not by a
  tolerance.** Three exist — `CorrectionCube`, `ToneCurve.generated` and `ToneCurve.solvedGamma` —
  and each is compared to the generator it replaced across every value it produces, to the
  precision the generator prints. That is what makes them transcriptions rather than opinions.
  Tolerances are for things that genuinely cannot agree, like this app against ffmpeg's own output.
- **Test an interpolation rule on something that is NOT smooth.** Deleting an entire branch of
  `Cube3D`'s tetrahedral decomposition left every test green, because the cube it was exercised on
  is Apple's conversion and picking the wrong tetrahedron on a smooth function moves a pixel by a
  fraction of a code value. `Cube3DTests` uses a pseudo-random cube against ffmpeg's `lut3d`, where
  the same mutation is out by half of full scale.
- **A timing assertion is worthless in the configuration nobody runs.** One asserted a frame took
  under 0.1s and passed, in a debug build whose real cost was 1.5 seconds. Swift's bounds and
  overflow checks make a tight pixel loop over a hundred times slower unoptimised. Either measure
  in release or do not measure; the numbers belong in a decision record either way.
- **Two renders of one clip at one timecode can write the same path.** A test held the URL of the
  first, rendered the second over it, and compared a frame against itself — reading 16 code values
  of error off a model that was within one. Decode a frame as soon as it lands, or put what
  produced it in the name.
- A test that cannot fail is worse than no test — it reads as coverage.

## Things that are settled, don't re-litigate

- **Tone, not colour.** Apple's CST is already colorimetrically accurate (traffic blue at B/G 1.99
  against a 1.98 spec, nothing applied). Hours went into "fixing" colour that was correct. The
  flatness was tone: ~25% too bright with nothing reaching black.
- **The shipped look is deliberately off-spec** (saturation 1.27 puts that blue at 2.39). That is
  the grade, not an error. Do not "correct" it toward the reference.
- **Rotation is an ingest concern.** No rotation logic in the pipeline; the source is trusted. The
  one guard decodes a frame and measures it, refusing non-portrait rather than squashing it.
- **The scene-linear filmic route was tried and lost on colour.** Its measurements are in
  `docs/adr/0002_KEEP_APPLES_CST.md`; the cubes themselves are gitignored, so `luts/filmic/` holds
  only `SOURCE.txt` on a fresh clone and is regenerated from `scripts/make-filmic-lut.py`.
- **An UNSET variable is not an empty one, and `grade_chain` depends on the difference.** Empty
  `LOOK_LUT` means a deliberate choice of no look; unset means nobody chose, which `look.json`
  answers. When the look stopped being a constant assigned at source time, two callers that
  sourced `lib.sh` and called `grade_chain` silently got a chain with no look filter in it, and
  both looked correct. The golden's freshness guard caught it; nothing else would have.
- **Look values live in `look.json`,** never hardcoded in a script. `grade.sh` broke this with its
  own copy of the tone block, so a grade from the Bench changed `shipped.cube` and the staged path
  while production kept rendering the old tone. `look()` has **no fallbacks** on purpose: a missing
  key must stop the run, not substitute a different look. That makes the key set a contract, and a
  test checks the scripts and `look.json` against each other.
- **`shipped.cube` freshness is by CONTENT, not mtime.** Each generated cube stamps its parameters
  into its `TITLE` and `make-tone-lut.py` skips the write when they already match. mtime cannot
  work: git does not preserve it, so on a fresh clone the committed cube always lands newer than
  `look.json` and would be trusted forever.
- **The grade chain and the delivery chain live once each, in `lib.sh`.** Both were copies that
  drifted: the delivery filters were three (two stage-3 scripts, now one `03-final.sh`
  parameterised by target, plus `grade.sh`), and the grade head was two, with nothing in the suite
  rendering the staged one. A test now fails if a stage script starts building either again. The
  measurements that justify each filter live next to its builder.
- **Never point `ffmpeg -y` at a delivery path.** It truncates the existing file before it knows
  whether the graph initialises, so a failed re-render destroys the approved deliverable — measured
  at 0 bytes with ffmpeg exiting 234. Use `render_delivery`, which stages, checks and tags before
  installing. A test pins this, because it was reintroduced once while rewriting stage 3.
- **Orientation is settled in ADR 0005, the media layout in ADR 0006.** Removing rotation in pieces
  left a runbook step telling you to pass an argument that was silently ignored; when a concept is
  deleted, grep for its name in prose too.

- **The app builds RELEASE by default, and that is not a preference.** The live preview grades a
  whole frame per control change; unoptimised that is 1.5 seconds against 12.7ms. `make-app.sh`
  therefore takes `--debug`, not `--release`. A debug build does not feel slow, it feels broken.
- **The preview is live, and the render on release is still what gets judged.** Every control moves
  the picture immediately because `LiveChain` runs the whole chain in-process on a decoded source
  frame. It is within about 1.3 code values of the render, measured against it on real footage by
  `LiveChainTests`. Do not "simplify" it back to grading a converted frame: that is what made the
  correction stage impossible to preview, which is `docs/adr/0009`.

## Style

Tabs in shell scripts. Comments explain *why* — a rejected alternative, a measurement, a trap —
never *what*. Most of the comments in `scripts/` exist to stop a future reader "simplifying" away
something that was expensive to learn.
