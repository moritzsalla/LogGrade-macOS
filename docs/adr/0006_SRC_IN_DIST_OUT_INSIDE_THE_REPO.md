# src/ in, exports out, inside the work dir

Footage lives in `src/`. Each run's deliverables go to a dated `LogGrade export <date time>/`, and
everything else a render writes (reports, cubes, stabilisation, proofs) to a hidden `.loggrade/`,
both in the work dir, which is the repo unless moved. Media is never committed. `GRADE_WORK_DIR`,
or a path in `.workdir`, moves both elsewhere, such as an external disk. That is opt-in, because the
default should work with no configuration. The app sets `LOGGRADE_CACHE`, so its working files go
to `~/Library/Caches/LogGrade` rather than beside a person's footage.

## Consequences

- **`.gitignore` excludes `src/*`, not `src/`.** Git cannot re-include anything under an excluded
  directory, and `src/.gitkeep` must survive: nothing creates `src/`.
- **`WORK` and `ROOT` mean different things, and confusing them is silent.** `WORK` is the work-dir
  root; `ROOT` is the repo. Three scripts checked free space under `$ROOT` while writing under
  `$WORK`. Without a `.workdir` those are the same path, so the bug was invisible locally and
  shipped. Media takes `WORK`; only LUTs and scripts take `ROOT`.
- **No marker files in output folders.** Checked-in `.gitkeep` output folders lived in the repo while the
  output went to the work dir, and ffmpeg only reported the missing directory at the end of a long
  encode. Every stage creates its own output directory.
- **Tests point `GRADE_WORK_DIR` somewhere genuinely else** and do not pre-create output folders. A
  test that does create them cannot see either bug.
