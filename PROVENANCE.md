# Provenance

The engine in `scripts/`, its tests, the LUTs, `look.json`, `bench/` and the docs are a fork of
`ffgrade`, imported verbatim at commit:

    80e8c16c109c3b3f542997f103ca744e3291c987

**The precursor is frozen and is not modified.** Not a branch, not a commit, not a file. That
constraint has one cost worth stating plainly: fixes made here never reach it, and it keeps its
known debt forever. What it buys is an oracle. At default settings this fork must render
byte-identical output to the precursor, which `tests/conformance.sh` asserts — so the copy can be
instrumented and then parameterised without anyone having to take it on faith that the image
survived.

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

Each of these is a thing to fix *here*, since the precursor cannot be touched.

- The stale-transform branch warns and renders anyway. It is the one place the pipeline does not
  fail loudly.
- An unmerged branch in the precursor carries input validation that never landed — a numeric guard
  for every value spliced into a filter graph, and a clip-name guard. It cannot be merged there
  because it predates the chain dedupe and would reinstate an inlined copy of the chain. It belongs
  here instead.
- `luts/apple/SOURCE.txt` says the Apple Log transfer function is proprietary. Apple published it,
  in the Apple Log Profile white paper. The Rec.709 cube is the part that is not reproducible,
  because it carries an unpublished display rendering.
- `docs/BACKLOG.md` asks for a fifth decision record when six exist, and `docs/PIPELINE.md` still
  opens with "the four decisions".
