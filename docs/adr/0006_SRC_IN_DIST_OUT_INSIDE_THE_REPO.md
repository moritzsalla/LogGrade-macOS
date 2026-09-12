# src/ in, dist/ out, inside the repo — with an opt-in work dir

Footage lives in `src/` and everything a render writes lands in `dist/`, both inside the repo. The
media itself is never committed: `.gitignore` excludes the *contents* of those folders while
keeping the folders and their `.gitkeep` markers, so a fresh clone has somewhere to write.

The alternative was keeping media outside the repo entirely and passing a path in. That is still
available as an opt-in — `GRADE_WORK_DIR`, or a path in `.workdir` — for the case where the footage
lives on an external disk. But it is not the default, because the default should be the one that
works with no configuration at all.

## Consequences

- **`.gitignore` excludes `src/*`, not `src/`.** Git cannot re-include anything beneath an excluded
  *directory*, so `src/` would also swallow the `.gitkeep` markers the pipeline depends on.
- **Two paths now mean different things, and confusing them is silent.** `WORK` is the work-dir
  root; the repo root is `ROOT`. Three scripts checked free space on `$ROOT/dist` while writing to
  `$WORK/dist`, and with no `.workdir` present those resolve to the same path — so the defect was
  invisible locally and shipped. Anything that touches media takes `WORK`; only LUTs and scripts
  take `ROOT`.
- **The `.gitkeep` markers are not a substitute for `mkdir -p`.** With a work dir set, the markers
  live in the repo and the output does not, so every stage must create its own output directory.
  Relying on the markers meant ffmpeg reported a missing directory at the *end* of a full-length
  encode.
- **A test that pre-creates the output folders cannot see either bug.** The tests that cover this
  point `GRADE_WORK_DIR` somewhere genuinely else, and one of them deliberately does not create
  `dist/03-final`.
