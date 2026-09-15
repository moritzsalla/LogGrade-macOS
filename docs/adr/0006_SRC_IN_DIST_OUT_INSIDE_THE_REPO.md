# src/ in, dist/ out, inside the repo, with an opt-in work dir

Footage lives in `src/`, and everything a render writes goes to `dist/`, both inside the repo. Media
is never committed. `GRADE_WORK_DIR`, or a path in `.workdir`, moves both elsewhere, such as an
external disk. That is opt-in, because the default should work with no configuration.

## Consequences

- **`.gitignore` excludes `src/*`, not `src/`.** Git cannot re-include anything under an excluded
  directory, and `src/.gitkeep` must survive: nothing creates `src/`.
- **`WORK` and `ROOT` mean different things, and confusing them is silent.** `WORK` is the work-dir
  root; `ROOT` is the repo. Three scripts checked free space on `$ROOT/dist` while writing to
  `$WORK/dist`. Without a `.workdir` those are the same path, so the bug was invisible locally and
  shipped. Media takes `WORK`; only LUTs and scripts take `ROOT`.
- **No marker files in `dist/`.** Checked-in `.gitkeep` output folders lived in the repo while the
  output went to the work dir, and ffmpeg only reported the missing directory at the end of a long
  encode. Every stage creates its own output directory.
- **Tests point `GRADE_WORK_DIR` somewhere genuinely else** and do not pre-create output folders. A
  test that does create them cannot see either bug.
