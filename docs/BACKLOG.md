# Backlog

Everything raised and not finished. Ordered by what blocks what, not by size.

**Inherited from the precursor.** Most of what follows was written about that shoot and still reads
as true of the engine; the app's own work is tracked outside this file. `PROVENANCE.md` says what
came across.

## Blocking the rest of the shoot

**Sign off the v4 look.** The current proof carries four changes on top of the approved grade:
black point lifted 0.015 → 0.025 with gamma eased 2.09 → 2.02 (shadow detail), stabilisation,
chroma-only denoise for the sign shimmer, and clustered grain moved after the sharpener. Until
that is judged, the rest of the shoot should not be rendered against it.

**Run the remaining clips.** Per-clip procedure in `docs/BATCH_RUNBOOK.md`. One thing there is
per-clip and must not be inherited from IMG_0609: the Feed crop offset, since 750 is this clip's
composition only.

## Worth doing next

**A drag-and-drop wrapper.** A Folder Action or droplet: drop a folder, finals appear, a plain
report says what happened. `scripts/grade.sh` is already the engine — folder in, finals out, no
intermediates. This is a thin wrapper over working, measured code.

**Judge the grain strength by eye.** `GRAIN_STRENGTH=8` is a starting suggestion, not a decision.
The measurements behind clustered-vs-per-pixel grain are settled (see `docs/PIPELINE.md`); the
amplitude is the one number that wants an eye. Override with `GRAIN_STRENGTH=n ./scripts/…`.

**Tonal weighting for grain.** Real film grain peaks in the midtones and falls off in deep shadow;
the current grain is flat across the tonal range. Needs a luma-derived mask via `geq`. Untested.

**Audio.** Measured and clean — PCM stereo, unclipped, 24 dB crest, genuine L/R decorrelation
(0.54), no lossy codec ever applied. Two things available: a high-pass around 60–80 Hz removes
rumble that is currently the loudest thing in the file, and a separate ambience recording (phone
set down, not held) would get street detail that handheld capture cannot. Nothing to undo first.

## Cleanups

**`spec` vs `target` in the Bench's code.** `CONTEXT.md` rules that a *spec* is the published RAL
value you measure against and deliberately depart from; *target* is ruled out because it implies
somewhere to arrive. The Bench's `SAMPLERS` still use `target:`. The code should change, not the
glossary — README's "accuracy is not a grade" only parses under the ruled meaning.

**`02-grade.sh`'s header uses "look" twice for two different things.** Once for the Portra LUT,
once for the whole grade. One-line fix next time that file is open.

**`dist/proofs/` is doing three jobs** — proofs, variant renders, and ladder images. Nothing
references the folder, so splitting it is free whenever the naming settles.

~~**A fifth ADR.**~~ Written, as `docs/adr/0007_THE_GRADE_IS_DECIDED_IN_A_BENCH_AND_SENT_AS_DATA.md`.
The item said "a fifth" when six already existed, which is what a count in prose does.

## Considered and declined

Kept here so they are not re-litigated from scratch.

- **A better Portra LUT.** Every freely reachable one is the same coarse 13³ G'MIC grid. A real
  improvement means a print-film emulation (Kodak 2383 class), which expects log or Cineon input —
  a different pipeline shape, not a drop-in swap.
- **The scene-linear filmic route.** Architecturally correct and it lost on colour; kept in
  `luts/filmic/` with its measurements. See ADR-0002.
- **Playwright tests for the Bench.** The property that actually matters — the Bench's curve maths
  matching the renderer's — is tested directly by `tests/grade-parity.py`, which is cheaper and
  more precise than driving a browser.
- **An accessibility audit of the Bench.** Single-user desktop tool. Revisit if it is ever shared.
- **Python linting.** Two scripts, ~300 lines. Run `ruff` once if it bothers you.
