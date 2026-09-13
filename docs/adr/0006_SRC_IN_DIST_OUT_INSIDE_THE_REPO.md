# src/ in, dist/ out, inside the repo — with an opt-in work dir

Footage lives in `src/` and everything a render writes lands in `dist/`, both inside the repo. The
media itself is never committed: `.gitignore` excludes the contents of `src/` while keeping the
folder, and excludes `dist/` outright.

The alternative was keeping media outside the repo entirely and passing a path in. That is still
available as an opt-in — `GRADE_WORK_DIR`, or a path in `.workdir` — for the case where the footage
lives on an external disk. But it is not the default, because the default should be the one that
works with no configuration at all.

## Consequences

- **`.gitignore` excludes `src/*`, not `src/`.** Git cannot re-include anything beneath an excluded
  *directory*, so `src/` would also swallow its `.gitkeep`. That marker stays because nothing
  creates `src/`: it is where you put footage, and an empty folder is the only thing in the repo
  that says so.
- **Two paths now mean different things, and confusing them is silent.** `WORK` is the work-dir
  root; the repo root is `ROOT`. Three scripts checked free space on `$ROOT/dist` while writing to
  `$WORK/dist`, and with no `.workdir` present those resolve to the same path — so the defect was
  invisible locally and shipped. Anything that touches media takes `WORK`; only LUTs and scripts
  take `ROOT`.
- **`dist/` carries no markers at all, and that followed from fixing a bug.** It used to hold a
  `.gitkeep` in each of `01-baseline`, `02-graded`, `03-final` and `frames`, so that a fresh clone
  had somewhere to write. That reasoning was wrong the moment a work dir was set: the markers lived
  in the repo and the output did not, and ffmpeg reported the missing directory at the *end* of a
  full-length encode. Every stage now creates its own output directory, which makes the markers
  dead weight — so they are gone and `dist/` is ignored whole.
- **A test that pre-creates the output folders cannot see either bug.** The tests that cover this
  point `GRADE_WORK_DIR` somewhere genuinely else, and one of them deliberately does not create
  `dist/03-final`.
