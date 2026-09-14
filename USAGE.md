# Usage

The controls, and the CLI underneath them. [`README.md`](README.md) says what this is and why;
this is the reference you reach for mid-task.

Every knob is an environment variable. That is not minimalism — the app sets these same variables
and reads the engine's events, and never builds a filter graph of its own
([ADR 0008](docs/adr/0008_THE_APP_DRIVES_THE_CHAIN_AND_NEVER_REBUILDS_IT.md)), so anything the
interface can do is reachable from a shell.

---

## The app

```sh
./app/make-app.sh          # builds dist/LogGrade.app
./app/make-app.sh --debug  # unoptimised, for debugging the app itself
```

**Build it optimised.** The live preview grades a whole frame per slider tick, and Swift's bounds
and overflow checks make that 1.5 seconds in a debug build against 12.7ms in a release one. A debug
build does not feel slow, it feels broken — which is why `--debug` is the flag rather than
`--release`.

Drop clips on the window, or File ▸ Add Clips. Pick one, open a stage in the inspector, and move a
control: the picture follows it, and on release the engine renders the same frame through the real
chain. There is no preview button.

| | |
|---|---|
| hold **C** | the picture before the change you are making |
| double-click a control's name | back to the preset's value |
| drag on the picture | place the crop window; arrow keys nudge, or type the offset |

Already-converted footage is refused, since grading it again applies Apple's conversion twice.
The interface decisions are in [`docs/APP_DESIGN.md`](docs/APP_DESIGN.md).

---

## One clip, one pass

```sh
./scripts/grade.sh src/                  # a whole shoot folder
./scripts/grade.sh src/IMG_0609.mov      # one clip
./scripts/grade.sh src/A.mov src/B.mov   # named clips
```

A folder expands to its `.mov` files. Output lands in `dist/03-final/`, and a per-run report in
`dist/reports/`. Roughly three minutes a clip.

The report is what to read when a render is slow or wrong. Beyond what the terminal shows, it
records the machine, the ffmpeg version, the engine commit, a hash of the look file and every
effective knob; per clip, the source's length and frame count, the time each phase took, and each
encode's speed and bitrate; the exact ffmpeg command and filter graph of every render; and a
summary of where the run's wall time went.

This is the production path: source to deliverable in a single ffmpeg invocation. The staged
scripts below do the same work in three passes and exist for a different reason.

### What to deliver

| | |
|---|---|
| `DELIVERABLES=<list>` | what to render, comma separated. Default `reels`. |
| `WIDTH=<px>` | the delivery width every deliverable shares. Defaults to `HEIGHT`'s 9:16 width. |
| `HEIGHT=<px>` | height of the 9:16 reference frame, default 1920. It sets the shared width. |
| `CROP_Y=<px\|centre>` | vertical offset for every deliverable that crops and carries no offset of its own. **No default.** |
| `FPS_OUT=<n>` | output frame rate. Default is the source's. |

`FPS_OUT` accepts only an integer relation — dropping or repeating whole frames. Anything that
would need retiming is refused rather than interpolated, because without motion compensation it
judders, and 24 to 30 is the case that tempts people.

### The look

| | |
|---|---|
| `LOOK=<name\|none>` | which film-emulation cube, by stem from `luts/looks/`. `none` for a neutral grade. |
| `PRINT=<name\|none>` | which print-film cube follows the look, by stem from `luts/print/`. |
| `GRAIN_STRENGTH=<n>` | override `look.json`'s grain strength. |
| `CORRECT_SIZE=<n>` | points per axis in the input-correction cube, default 33. |
| `LOOK_FILE=<path>` | read the look from somewhere other than `look.json`. |

Everything else about the look lives in `look.json`, which is the single source every stage reads.
That includes `halation` — the glow bright things spill past their edges, added before the
conversion — whose `strength` of 0 leaves the stage out of the graph entirely — the `print` block,
and a `strength` on both `look` and `print` that blends each cube back toward its input, and
`grain.shadows` / `grain.highlights`, the grain's weight at black and at white, where 1 for both is
flat grain.
`look()` has no fallbacks on purpose: a missing key stops the run rather than quietly substituting
a different look.

### Exposure matching

| | |
|---|---|
| `MATCH=1` | *(default)* solve each clip's gamma to land on `look.json`'s `match.reference_yavg`. |
| `MATCH=batch` | solve against the median of **this run's own clips**. |
| `MATCH=0` | no matching; use `look.json`'s gamma raw. |
| `YAVG_IN=<n>` | the clip's post-CST mean, already measured. Skips the probe. |

Clips shot across an evening land differently under one curve, so each clip's exposure is measured
and its gamma solved to bring them together. *Where* they land is the part that does not travel:
`MATCH=1` anchors on 609, the luma mean of one frame of one clip of one shoot. Right for that
footage, meaningless for anyone else's, and applied silently either way.

Use `MATCH=batch` for a shoot that is not the reference shoot; it anchors on the footage in front
of it. Use `MATCH=0` when you want the frozen curve exactly. The default is unchanged because
changing it would change every existing render —
[ADR 0011](docs/adr/0011_THE_EXPOSURE_REFERENCE_CAN_COME_FROM_THE_SHOOT.md).

`YAVG_IN` exists because the probe reads a number that does not change when a look does, so an
interface adjusting a curve would re-measure the same value on every render. The render is
identical either way.

### Stabilisation

| | |
|---|---|
| `STAB=0` | skip stabilisation entirely. Faster. |
| `SMOOTHING=<n>` | frames of camera-path lowpass; higher is closer to locked-off. |

Detection runs on the source and costs about 65 seconds for a 26-second 4K clip. The warp is
applied at full resolution, before the downscale, so it resamples at 4K rather than at delivery
size.

### Seeing it before you commit

| | |
|---|---|
| `PROOF=<seconds>` | render that many seconds through the real chain into `dist/proofs/`. |
| `FRAME=<seconds>` | render one still at that timecode through the grade chain, and stop. |
| `FRAME_HEIGHT=<px>` | height of that still, default 1440. |
| `FRAME_STAGE=source` | the same frame with no grade chain at all, resampled identically. |
| `DRY=1` | plan only, render nothing. |

`PROOF` is the one to reach for first: it is the identical filter graph, not a lookalike, so a look
can be judged in seconds instead of minutes. Proofs are named so they cannot be mistaken for
deliverables, and land outside the folder you upload from.

`FRAME` covers the grade only — a still cannot show grain, the sharpener, the chroma denoise, the
stabiliser or the dither, all of which are delivery-stage. It is the app's exact preview.

`FRAME` and `PROOF` together are refused: they answer different questions and neither is a fallback
for the other.

### Driving it from a program

| | |
|---|---|
| `JSON=1` | one machine-readable event per line on stdout. |
| `GRADE_WORK_DIR=<path>` | work somewhere other than the repo. |

Under `JSON=1` the human lines go only to the run report, leaving stdout to the event stream. Named
codes go to stderr either way, so a consumer that never sets `JSON=1` still learns why a clip was
skipped.

`GRADE_WORK_DIR` can also be written into a `.workdir` file at the repo root, one path per line,
`~` accepted. `src/` is read-only for the life of a project; everything generated goes to `dist/`.

---

## Deliverables

A deliverable is a name, an aspect and an optional crop offset — not a size written into the
pipeline ([ADR 0010](docs/adr/0010_A_DELIVERABLE_IS_DATA_NOT_A_CASE_BRANCH.md)). A spec is either a
preset name or:

```
name:aspect-w:aspect-h[:offset]
```

where `offset` is a number of pixels or the word `centre`.

| preset | aspect | output name |
|---|---|---|
| `reels` | 9:16 | `<clip>_reels-stories_9x16.mp4` |
| `feed` | 4:5 | `<clip>_feed_4x5.mp4` |

```sh
DELIVERABLES=reels,feed CROP_Y=820 ./scripts/grade.sh src/IMG_0609.mov
DELIVERABLES='reels,feed:4:5:centre,square:1:1:840' ./scripts/grade.sh src/IMG_0609.mov
DELIVERABLES=wide:16:9:400 ./scripts/grade.sh src/IMG_0609.mov
```

Height follows the aspect off the shared width, so every deliverable is the same horizontal
resolution — the platform re-encodes to a fixed width, and two deliverables differing in it would
be re-encoded differently for no reason anyone chose. At the default 1080 wide:

```
reels: 1080x1920
feed: 1080x1350 cropped at 570
square: 1080x1080 cropped at 840
wide: 1080x606 cropped at 400
```

Each resolved size is printed per clip, because it is derived rather than typed. A `HEIGHT` that is
not a multiple of 16 lands a 9:16 frame a pixel or two off the number you asked for.

A shape that is a crop of the master gets one, computed from the frame actually on disk. A shape
that is already the master's own shape gets no crop filter at all. A shape taller than the source
is refused — there is no window to take.

**Sharpening and grain were tuned at 1080×1920.** Both scale with height — radius formula r=5×h÷1920 with min 3 and odd constraint, and grain from a half-resolution plate. Measured in [`docs/PIPELINE.md`](docs/PIPELINE.md) § Sharpen and grain at other heights: kernel values quantise to 3 px (at 960 and 1280), 5 px (at 1920), and 7 px (at 2560), meaning smaller heights put different real-world detail sizes through the same kernel.

---

## The crop offset

**There is no default.** A deliverable that crops is refused without one:

```
REFUSING: 'feed' crops, and no offset was given.
  Where the window sits is a composition call per clip — there is no sensible
  default, so this is refused rather than guessed.
```

It used to default to 750, which is one clip's composition and nobody else's. Centre is the obvious
replacement and is refused as one for the reason the README gives: default the crop to centre and a
batch of twelve gives you twelve files that all look finished and are all framed wrong.

So centre is available, but only as something you say:

```sh
CROP_Y=centre ./scripts/grade.sh src/IMG_0609.mov        # every cropping deliverable
DELIVERABLES=feed:4:5:centre ./scripts/grade.sh src/     # just this one
```

`centre` is resolved per clip against the measured frame — which a fixed pixel offset cannot be —
and the row it lands on is printed. A deliverable's own offset beats `CROP_Y`.

---

## The staged path

```sh
./scripts/01-baseline.sh IMG_0609          # source -> baseline (CST + colour tags)
./scripts/02-grade.sh    IMG_0609          # baseline -> graded master
./scripts/00-stabilise-detect.sh IMG_0609  # optional: analyse camera motion
./scripts/03-final.sh    IMG_0609 feed 820 # master -> one deliverable
```

Three passes, writing two ProRes intermediates of about 2.5GB per clip and decoding the footage
three times. `grade.sh` collapses all of it into one filter graph, which removes two full encodes,
two full decodes and roughly 5GB of disk per clip.

Use the staged path when you want to re-tune a look without redoing the conversion — the master is
the only file a re-export is allowed to start from. For production runs, use `grade.sh`.

It cannot carry a stage that runs before the conversion, because its baseline has already been
converted. `02-grade.sh` therefore refuses a look with an active input correction or halation,
rather than rendering a master without them.

`00-stabilise-detect.sh` is numbered 00 but run last in practice: it needs the master, and it is
only worth running on a clip shot handheld. The finals skip stabilisation silently when no `.trf`
exists, so it is opt-in per clip.

`03-final.sh` takes the same deliverable specs as `DELIVERABLES`, one at a time, with the offset as
a positional argument. `ACCEPT_STALE=1` delivers despite a transform older than its source — i.e.
unstabilised on purpose. Without it a stale transform is refused, because this stage has no detect
pass and the alternative is a file that looks finished and quietly lacks the stabilisation.

---

## Checking your work

```sh
./scripts/check.sh                 # shellcheck, grade golden, Swift suite, render golden, bats
./scripts/check.sh --conformance   # ...and report whether the default still matches the precursor
./scripts/check.sh --allow-skips   # accept a partial run on purpose
```

A missing tool is a **failure, not a pass**. The run records what did not execute and exits
non-zero naming it, because this command used to exit 0 having run only part of itself — so "green"
could mean "linted nothing".

The **render golden** renders one clip through the real chain and compares its stream hash with the
default image recorded in `tests/fixtures/render-golden.json`. If you changed the image on purpose,
look at the two renders in `dist/golden/` and record the new one with the reason:

```sh
./tests/render-golden.sh --regenerate "grain strength re-tuned on the Sep shoot"
```

`--conformance` renders through the frozen precursor too and *reports* whether the default still
matches it. It costs minutes, and a difference does not fail the run: the precursor is where this
came from, not what the image must be. See [ADR 0014](docs/adr/0014_THE_PRECURSOR_IS_PROVENANCE_NOT_THE_ORACLE.md).

---

## Named codes

Every refusal and degraded state prints `GRADE_CODE=<NAME>` on stderr beside the human sentence, so
a consumer never has to match on prose. The sentence is the thing that gets reworded; the code is
the contract.

| code | means |
|---|---|
| `REFUSE_NO_ARGS` | no clips or folders were given |
| `REFUSE_NOT_FOUND` | an argument names nothing on disk |
| `REFUSE_NOT_PORTRAIT` | the clip decodes landscape; vertical delivery would squash it |
| `REFUSE_DELIVERABLE` | a deliverable spec is not a preset and not `name:aw:ah[:offset]` |
| `REFUSE_NO_DELIVERABLES` | `DELIVERABLES` is empty, so there is nothing to render |
| `REFUSE_CROP_NO_OFFSET` | a deliverable crops and no offset was given |
| `REFUSE_CROP_WINDOW` | the crop window does not fit the source |
| `REFUSE_MATCH_MODE` | `MATCH` is not `0`, `1` or `batch` |
| `REFUSE_BATCH_NO_PROBE` | `MATCH=batch`, but no clip's exposure could be measured |
| `REFUSE_FPS_RETIME` | `FPS_OUT` is not an integer relation to the source |
| `REFUSE_PROOF_AND_FRAME` | both were set; they answer different questions |
| `REFUSE_FRAME_STAGE` | `FRAME_STAGE` is neither `graded` nor `source` |
| `REFUSE_STAGED_PRE_CONVERSION` | `02-grade.sh` was given a look with a correction or halation, which a converted baseline cannot carry |
| `RENDER_FAILED` | a clip's render failed; the previous output was left as it was |
| `FRAME_FAILED` | a preview frame failed to render |
| `STALE_TRANSFORM` | the stabilisation transform is older than its source |
| `NO_TRANSFORM` | no transform exists, so the clip renders unstabilised |

The last three are states rather than refusals: a run continues past them. A failed clip never
takes the batch with it, and the run's exit status still reports that something failed.

---

## Before it runs

Apple's conversion LUT is not in the repo — its licence forbids redistribution.
[`luts/apple/SOURCE.txt`](luts/apple/SOURCE.txt) says how to fetch it, and nothing renders until it
is there.
