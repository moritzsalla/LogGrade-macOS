# The suite runs in parallel, and has a fast tier that is never the default

Work on this repo felt slow, and the explanation offered for it — renders, the suite, conformance —
was an impression. Nothing had timed the suite. This records what did, what changed because of it,
and the two remedies that were proposed and dropped on the numbers.

## What was measured

2026-09-14, the 8-thread Intel i7 this repo is developed on, idle, footage and Apple's cube present,
no test skipped. One run each: this ranks costs, it is not a benchmark.

| block of `check.sh` | serial |
|---|---|
| shellcheck | 5.5s |
| grade golden | 0.2s |
| `swift build` (warm) | 3.4s |
| `swift test` | 104s |
| bats | 165s (the tests themselves sum to 145s; the rest is fixtures and loading `lib.sh`) |
| **total** | **~278s** |

The cost is concentrated, which is what made tiering worth doing at all. In bats, twelve tests of
three seconds or more carry 82s of the 145, and one of them — `make-app.sh` building release —
is 37s alone. In Swift, five classes carry 76s of 103:

| Swift test | serial |
|---|---|
| `LiveChainTests` (four engine renders against the live chain) | 36.7s |
| `EndToEndTests` (the same render from the shell and the app) | 15.0s |
| `PreviewRendererTests` (a still through the real chain) | 8.7s |
| `DeliveryTests` (a queue delivery) | 8.0s |
| `ClipListTests` (real footage and a thumbnail) | 7.8s |

bats reports whole seconds only, which is why its threshold is three rather than something finer.

## What changed

**Both runners go parallel, and that is the larger win.** `swift test --parallel` took the Swift
block from 104s to 61s. `bats -j 8` took bats from 165s to 48s, against 71s at `-j 4` — the
throttling this machine does under load did not make fewer jobs faster. Both parallel runs passed
every test and left the working tree clean. The full `check.sh` went from ~278s to **126s**, with
no test removed from it.

**`check.sh --fast` leaves out the measured-slow tests** — the bats tests tagged `slow`, the five
Swift classes above, and `swift build` — and ran in **53.5s**. It says what it skipped, and the
full run stays the default: it is the command CLAUDE.md says to trust, and a default that quietly
ran less would be the "green but tested nothing" failure the missing-tool rule exists for.

**Four bats tests are `serial`.** The two `make-app.sh` tests both rebuild `dist/LogGrade.app`,
one asserting on its contents while the other may be replacing it. The two `02-grade.sh` tests
regenerate the repo's `luts/tone/shipped.cube` whenever `look.json` has moved, through one fixed
`.partial` name. They run one at a time, but alongside the parallel pass rather than after it,
because they conflict with each other and not with the rest.

## What parallel costs, and how it is paid for

**A parallel Swift run does not report skips.** The serial run printed "N tests skipped";
`--parallel` prints no summary, and its xUnit output in Swift 5.9 has no skip element. Nearly every
skip here means footage or Apple's cube is absent, both gitignored, so `check.sh` checks for those
directly and says so before anything runs.

**A fixed wait broke under load.** `RenderQueueTests.testCancelStopsTheEngineAndWhatItSpawned`
slept 1.5s for its stub engine to write a pid, which held serially and failed in the first full
parallel run. It polls now. Any other test that assumes how long something takes will show up the
same way, and the fix is the same: wait for the condition, not for a duration.

## Dropped

**A short excerpt of the footage.** The idea was that tests reading real footage would decode less.
The clip in `src/` is 4.9 seconds, every render in the suite is already a fraction of a second or
one frame, and ProRes is intra-only, so a seek costs nothing. An excerpt would save I/O on a file
the tests barely read.

**Caching rendered frames across runs.** `LiveChainTests` already renders its source frame once per
run. Its four exact renders are four different looks and share nothing. A cache that outlives a run
saves time only when nothing changed, which is when nobody runs the suite, and it is the stale
comparison CLAUDE.md warns about.

## Re-measuring

When a new test lands, time it rather than guess: `bats --timing -f '<name>' tests/`, or the
per-test seconds `swift test --filter <Class>` prints. Tag or list it if it crosses three seconds,
and update the tables above with a date rather than editing the old numbers.
