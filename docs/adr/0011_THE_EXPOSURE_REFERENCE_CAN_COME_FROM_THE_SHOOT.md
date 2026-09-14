# The exposure reference can come from the shoot, not from one frame of one clip

`look.json`'s `match.reference_yavg` is 609: the post-CST luma mean of one frame of IMG_0609, ~20
minutes before sunset on the 11 Sep house shoot. `grade.sh` solves every clip's gamma to land on
it, `MATCH=1` is the default, and it happens silently. For that shoot it is the right anchor. For
anyone else's footage, or for the same camera under different light, it is a number with no meaning
that still moves every clip's gamma.

`MATCH=batch` anchors on the median of the run's own clips instead, so a shoot is matched to
itself. `MATCH=1` and `MATCH=0` are unchanged.

## Why this is not the same kind of constant as the rest of look.json

The tone block, the trims and the grain strength are preferences, shipped as defaults, editable in
one file, with no fallbacks so that a missing one stops the run. They travel: another person's
numbers go in the same slots.

`reference_yavg` does not. It is a *measurement of a frame*, wearing a look value's clothes. Nothing
about it describes the grade; it describes the light on one afternoon. Shot-matching is genuinely
valuable — it is what makes one recipe mean one look across a shoot window — and what breaks is
anchoring it to an absolute that came from somewhere else.

## The default does not change

`MATCH=1` stays the default, and `batch` is opt-in. Changing the default would change the output of
every existing render, and `tests/conformance.sh` asserts this fork is still byte-identical to its
frozen precursor at default settings. That test is the oracle the whole fork rests on; a decision
that costs it is not worth the tidiness.

## Consequences

- **The median, and the lower one on an even count.** Picking a real clip's measurement beats
  averaging two into a number no clip has, and it makes the choice reproducible rather than
  dependent on how the list was ordered. The median clip lands on the look's own gamma exactly, by
  construction — it defines the reference.
- **Measured once, used twice.** The batch pre-pass probes every clip before the first render and
  the loop reads the results by position. Probing again in the loop would double the cost for a
  number that cannot have changed, and two copies of that probe command is how the `metadata=print`
  INFO-level bug would come back in one of them. `probe_yavg` is therefore one function in `lib.sh`
  with two callers.
- **Alignment is the sharp edge.** The measurements are found by position, so an index that did not
  advance past a skipped clip would hand every clip after it the previous clip's exposure — a wrong
  grade on a file that looks finished. A test covers it, and it had to be rebuilt once: the first
  version passed against a removed guard, because the clip it skipped was too short to measure and
  so could not tell a misaligned index from a correct one.
- **`matched` is computed numerically now.** `solve-gamma.py` prints `2.020` where `look.json` says
  `2.02`, so a string comparison reported a clip the solve had left exactly where it started as
  "(matched)". Harmless under `MATCH=1`, where landing precisely on the reference is a coincidence;
  under `MATCH=batch` the median clip lands there by construction, so the field would have been
  wrong for one clip in every run.
- **An unmeasurable run is refused, not substituted.** If not one clip can be probed there is
  nothing to match to, so `MATCH=batch` stops with `REFUSE_BATCH_NO_PROBE` rather than quietly
  falling back to `look.json`. A silent substitution is a different grade, which is the rule
  `look()` already follows for every other value.
- **One clip under `MATCH=batch` is a no-op on gamma,** since a single clip is its own median. That
  is the right answer rather than a special case: there is nothing to match it to.
- **Measured on the reference shoot,** the batch median of IMG_0607/0608/0609 is 609.7 — which is
  where 609 came from. So for the footage the look was tuned on, `batch` reproduces the shipped
  anchor, and for everything else it stops pretending that afternoon's light is universal.
