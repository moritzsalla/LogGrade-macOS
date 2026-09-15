# Usage

Every knob is an environment variable. The app sets the same ones and never builds a filter graph
itself ([ADR 0008](docs/adr/0008_THE_APP_DRIVES_THE_CHAIN_AND_NEVER_REBUILDS_IT.md)).

## Commands

```sh
./app/make-app.sh [--debug]                # dist/LogGrade.app, release by default
./scripts/grade.sh src/ | clip.mov ...     # source -> deliverables in dist/03-final/, report in dist/reports/
./scripts/01-baseline.sh IMG_0609          # staged: source -> baseline
./scripts/02-grade.sh    IMG_0609          # staged: baseline -> master (refuses correction or halation)
./scripts/00-stabilise-detect.sh IMG_0609  # staged, optional: camera motion
./scripts/03-final.sh    IMG_0609 feed 820 # staged: master -> one deliverable
./scripts/check.sh [--fast|--conformance|--allow-skips]
./tests/render-golden.sh [--regenerate "<why>"]
```

In the app: hold **C** to compare, double-click a control's name to reset it, drag on the picture
to place the crop.

Apple's conversion LUT is not in the repo; see [`luts/apple/SOURCE.txt`](luts/apple/SOURCE.txt).

## Environment variables

| variable | meaning |
|---|---|
| `DELIVERABLES=<list>` | presets or `name:aw:ah[:offset\|centre]`, comma separated. Default `reels` |
| `WIDTH=<px>` | shared delivery width. Default: `HEIGHT`'s 9:16 width |
| `HEIGHT=<px>` | 9:16 reference height, default 1920 |
| `CROP_OFFSET=<px\|centre>` | offset for cropping deliverables without their own: from the top, or from the left on a frame wider than the window. No default |
| `FPS_OUT=<n>` | output rate; integer relations only |
| `DELIVERY_BITS=8\|10` | 8: H.264, default. 10: HEVC Main 10, for a destination that keeps it (a Mac, a phone, an editor); social platforms re-encode to 8-bit |
| `AUDIO_HIGHPASS_HZ=<hz\|0>` | delivered-audio high-pass, default 60; 0 off. Never applied to the master |
| `CONVERT=<apple\|name>` | the conversion out of Apple Log: Apple's cube, or a film cube from `luts/film/`. Overrides `convert.cube` |
| `LOOK=<name\|none>` | film cube from `luts/looks/` |
| `PRINT=<name\|none>` | print cube from `luts/print/` |
| `GRAIN_STRENGTH=<n>` | overrides `look.json` |
| `CORRECT_SIZE=<n>` | correction cube size, default 33 |
| `LOOK_FILE=<path>` | alternative `look.json` |
| `MATCH=1\|batch\|0` | exposure match to `match.reference_yavg`, to the run's median, or off. Default `1` (ADR 0011). Under a film conversion `1` meters exposure and white balance in linear against `match.reference_stops` instead, and `batch` is refused |
| `YAVG_IN=<n>` | pre-measured post-CST mean; skips the probe |
| `STAB=0` | skip stabilisation |
| `FINISH=0` | skip the delivery finish: sharpener, denoise and gauge. With a neutral look, `MATCH=0` and `STAB=0`, a final is the CST alone |
| `SMOOTHING=<n>` | stabiliser lowpass, in frames |
| `PROOF=<seconds>` | render seconds through the real chain into `dist/proofs/` |
| `FRAME=<seconds>` | one graded still (the app's preview) |
| `FRAME_HEIGHT=<px>` | still height, default 1440 |
| `FRAME_STAGE=graded\|source` | still with or without the grade |
| `DRY=1` | plan only |
| `JSON=1` | one event per line on stdout |
| `GRADE_WORK_DIR=<path>` | work outside the repo; also read from `.workdir` |
| `ACCEPT_STALE=1` | `03-final.sh`: deliver despite a stale transform |

Presets: `reels` is 9:16, `<clip>_reels-stories_9x16.mp4`; `feed` is 4:5, `<clip>_feed_4x5.mp4`.
Everything else about the look lives in `look.json`. The film presets are complete look files in
`presets/`, and the app lists them: `LOOK_FILE=presets/rz67_portra400.json ./scripts/grade.sh clip.mov`.

## Named codes

Printed on stderr as `GRADE_CODE=<NAME>`. The code is the contract; the sentence may change.

| code | means |
|---|---|
| `REFUSE_NO_ARGS` | no clips or folders given |
| `REFUSE_NOT_FOUND` | an argument names nothing on disk |
| `REFUSE_DELIVERABLE` | a malformed deliverable spec |
| `REFUSE_NO_DELIVERABLES` | `DELIVERABLES` is empty |
| `REFUSE_CROP_NO_OFFSET` | a deliverable crops and has no offset |
| `REFUSE_CROP_WINDOW` | the crop window does not fit the source |
| `REFUSE_MATCH_MODE` | `MATCH` is not `0`, `1` or `batch` |
| `REFUSE_BATCH_NO_PROBE` | `MATCH=batch`, and no clip could be measured |
| `REFUSE_BATCH_FILM` | `MATCH=batch` under a film conversion |
| `REFUSE_FPS_RETIME` | `FPS_OUT` would need retiming |
| `REFUSE_UNMEASURED` | a clip's decoded frame could not be measured; the clip is skipped |
| `REFUSE_PROOF_AND_FRAME` | both set |
| `REFUSE_FRAME_STAGE` | `FRAME_STAGE` is neither `graded` nor `source` |
| `REFUSE_STAGED_PRE_CONVERSION` | `02-grade.sh` was given a correction or halation |
| `RENDER_FAILED` | a clip failed; previous output untouched |
| `FRAME_FAILED` | a preview frame failed |
| `STALE_TRANSFORM` | the transform is older than its source (a state; the run continues) |
| `NO_TRANSFORM` | no transform; renders unstabilised (a state; the run continues) |
