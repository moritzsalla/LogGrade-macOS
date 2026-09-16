# Usage

Every knob is an environment variable. The app sets the same ones and never builds a filter graph
itself ([ADR 0008](docs/adr/0008_THE_APP_DRIVES_THE_CHAIN_AND_NEVER_REBUILDS_IT.md)).

## Commands

```sh
./app/make-app.sh [--debug]                # dist/LogGrade.app, release by default
./scripts/grade.sh src/ | clip.mov ...     # source -> 'LogGrade export <date time>/', report in .loggrade/reports/
./scripts/01-baseline.sh IMG_0609          # staged: source -> baseline
./scripts/02-grade.sh    IMG_0609          # staged: baseline -> master (refuses correction or halation)
./scripts/00-stabilise-detect.sh IMG_0609  # staged, optional: camera motion
./scripts/03-final.sh    IMG_0609 feed 820 # staged: master -> one deliverable
./scripts/check.sh [--fast|--allow-skips]
./tests/render-golden.sh [--regenerate "<why>"]
```

In the app: hold **C** to compare, double-click a control's name to reset it, drag on the picture
to place the crop.

Nothing has to be downloaded: `luts/rendering/neutral.cube` is the shipped conversion.

## Environment variables

| variable | meaning |
|---|---|
| `DELIVERABLES=<list>` | presets or `name:aw:ah[:offset\|centre]`, comma separated. Default `reels` |
| `WIDTH=<px>` | shared delivery width. Default: `HEIGHT`'s 9:16 width |
| `HEIGHT=<px>` | 9:16 reference height, default 1920 |
| `CROP_OFFSET=<px\|centre>` | offset for cropping deliverables without their own: from the top, or from the left on a frame wider than the window. No default |
| `FPS_OUT=<n>` | output rate; integer relations only |
| `DELIVERY_CODEC=h264\|hevc\|hevc10\|prores422\|prores422hq` | default h264. hevc10 keeps 10 bits for a destination that plays them; ProRes is 10-bit 4:2:2 for an editor, mov only |
| `DELIVERY_QUALITY=auto\|high\|max` | encoder effort per codec, default auto; ProRes takes auto only |
| `DELIVERY_CONTAINER=mp4\|mov` | default mp4 |
| `DELIVERY_AUDIO=1\|0` | 0 delivers with no audio stream |
| `DELIVERY_BITS=8\|10` | old spelling of h264 / hevc10; must agree with DELIVERY_CODEC |
| `AUDIO_HIGHPASS_HZ=<hz\|0>` | delivered-audio high-pass, default 60; 0 off. Never applied to the master |
| `CONVERT=<name>` | the conversion out of Apple Log, from `luts/rendering/` or `luts/film/`. Overrides `convert.cube` |
| `GRAIN_STRENGTH=<n>` | overrides `look.json` |
| `CORRECT_SIZE=<n>` | correction cube size, default 33 |
| `LOOK_FILE=<path>` | alternative `look.json` |
| `MATCH=1\|0` | meter each clip's exposure and white balance in linear against `match.reference_stops`, before the conversion, or render it as shot. Default `1` |
| `STAB=0` | skip stabilisation |
| `FINISH=0` | skip the delivery finish: sharpener, denoise and gauge. With a neutral look, `MATCH=0` and `STAB=0`, a final is the conversion alone |
| `SMOOTHING=<n>` | stabiliser lowpass, in frames |
| `PROOF=<seconds>` | render seconds through the real chain into `.loggrade/proofs/` |
| `EXPORT_DIR=<dir>` | where deliverables land; default `<work>/LogGrade export <date time>` |
| `FRAME=<seconds>` | one graded still (the app's preview) |
| `FRAME_HEIGHT=<px>` | still height, default 1440 |
| `FRAME_STAGE=graded\|source` | still with or without the grade |
| `DRY=1` | plan only |
| `JSON=1` | one event per line on stdout |
| `GRADE_WORK_DIR=<path>` | work outside the repo; also read from `.workdir` |
| `ACCEPT_STALE=1` | `03-final.sh`: deliver despite a stale transform |

Presets: `reels` is 9:16, `<clip>_reels-stories_9x16.mp4`; `feed` is 4:5, `<clip>_feed_4x5.mp4`.
Everything else about the look lives in `look.json`. The film presets are complete look files in
`presets/`, and the app lists them: `LOOK_FILE=presets/portra160.json ./scripts/grade.sh clip.mov`.

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
| `REFUSE_MATCH_MODE` | `MATCH` is not `0` or `1` |
| `REFUSE_FPS_RETIME` | `FPS_OUT` would need retiming |
| `REFUSE_UNMEASURED` | a clip's decoded frame could not be measured; the clip is skipped |
| `REFUSE_PROOF_AND_FRAME` | both set |
| `REFUSE_FRAME_STAGE` | `FRAME_STAGE` is neither `graded` nor `source` |
| `REFUSE_STAGED_PRE_CONVERSION` | `02-grade.sh` was given a correction or halation |
| `RENDER_FAILED` | a clip failed; previous output untouched |
| `FRAME_FAILED` | a preview frame failed |
| `STALE_TRANSFORM` | the transform is older than its source (a state; the run continues) |
| `NO_TRANSFORM` | no transform; renders unstabilised (a state; the run continues) |
