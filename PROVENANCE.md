# Provenance

The engine in `scripts/`, its tests, the LUTs, `look.json`, `bench/` and the docs are a fork of
`ffgrade`, imported verbatim at commit:

    80e8c16c109c3b3f542997f103ca744e3291c987

**The precursor is frozen and is not modified.** Not a branch, not a commit, not a file. That
constraint has one cost worth stating plainly: fixes made here never reach it, and it keeps its
known debt forever. What it bought was an oracle. At default settings this fork rendered
byte-identical output to the precursor, which `tests/conformance.sh` asserted, so the copy could be
instrumented and then parameterised without anyone having to take it on faith that the image
survived.

It is provenance now, not the oracle (ADR 0014). The precursor was the best edit at the time, and
holding the default to it forbade improving on it. The default image is held by
`tests/render-golden.sh`, seeded from a render whose stream hash matched the precursor's, and it moves
on purpose with a recorded reason. `tests/conformance.sh` still runs and reports whether the default
has departed.

That test rests on a measurement rather than an assumption. Two renders of one clip through the
precursor, minutes apart, produced byte-identical files and identical packet-stream hashes. Nothing
in either render path passes `-bitexact`; it simply happens that this ffmpeg build stamps no
timestamp into the container. If a future build starts doing so, compare
`ffmpeg -i out.mp4 -map 0 -c copy -f md5 -` instead of the files, and say so here.

## What was inherited

Everything the precursor tracked at that commit, plus Apple's two conversion cubes, which are
gitignored here for the same licensing reason they are gitignored there — see
`luts/apple/SOURCE.txt`.

## What was deliberately left behind

Nothing. The inherited docs describe the precursor's shoot and its decisions, and correcting them
for this repo is its own piece of work rather than something to do while importing: an import that
also edits is an import nobody can verify.

## Inherited debt, known at import

Each of these was a thing to fix *here*, since the precursor cannot be touched. All four are
resolved; the list stays so the precursor's behaviour is not mistaken for this fork's.

- ~~The stale-transform branch warns and renders anyway.~~ Resolved: `03-final.sh` refuses a stale
  transform and emits `STALE_TRANSFORM`, unless `ACCEPT_STALE=1` says unstabilised is intended;
  `grade.sh` recomputes one instead.
- ~~An unmerged branch in the precursor carries input validation that never landed.~~ Resolved:
  `require_number` and `require_clip_name` live in `scripts/lib.sh`, and the entry scripts call them
  on every value spliced into a graph or a path.
- ~~`luts/apple/SOURCE.txt` says the Apple Log transfer function is proprietary.~~ Resolved: it now
  says the function is published and that the Rec.709 cube's display rendering is what is not.
- ~~`docs/BACKLOG.md` asks for a fifth decision record when six exist, and `docs/PIPELINE.md` still
  opens with "the four decisions".~~ Resolved: the BACKLOG item is struck, and `docs/PIPELINE.md`
  points at `docs/adr/` as the index instead of counting it.
