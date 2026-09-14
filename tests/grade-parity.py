#!/usr/bin/env python3
"""
Render the probe through ffmpeg and keep the golden every approximation of it is measured against.

WHAT THIS FILE IS
-----------------
ffmpeg's own output over a fixed probe image, recorded per case in tests/fixtures/grade-golden.json
alongside the tolerances that say how far an approximation is allowed to sit from it. It is the
ORACLE, and it is reached through `grade_chain` sourced out of scripts/lib.sh rather than
transcribed here. That is the point: this cannot drift from production, because it calls the same
builder production calls. The suite's "grade chain is built in exactly one place" test keeps that
true.

WHO READS THE GOLDEN, AND WHY THE COMPARISON IS NOT HERE ANY MORE
-----------------------------------------------------------------
It used to be the browser Bench, whose page reimplemented the grade in JavaScript, and this
file ran that JavaScript under node and compared it against the cases below. The Bench is gone —
the Mac app's inspector replaced it, and app/Sources/GradeKit/Scopes.swift carries the same RAL
references its samplers did. docs/adr/0007 records that decision.

So the per-pixel comparison lives in app/Tests/GradeKitTests/LiveGradeTests.swift, which reads this
same golden and holds Swift's `LiveGrade` to the numbers in it. Removing the Bench took the tone
and trim arithmetic from three implementations (JavaScript, Swift, ffmpeg) down to two and cost no
coverage, because the oracle was never the Bench: it was always ffmpeg's recorded output.

WHAT THIS FILE STILL GUARDS on its own, all of which can fail:

  1. FRESHNESS of the golden against the chain that produced it, by content (see below);
  2. the PROBE image against the hash recorded in the golden that was measured on it;
  3. the `shipped` and `tone-only` cases against look.json's tone and colour values.

`grade_worst_by_case` IS CARRIED FORWARD, NOT RECOMPUTED. Those tolerances measure an approximation
against ffmpeg, and with the Bench gone the only approximation left is Swift's — which this file
cannot run. So `--regenerate` copies the existing numbers forward and says so loudly rather than
inventing or dropping them. If you change the chain they are stale by construction: re-measure in
LiveGradeTests and write the new numbers in deliberately. Dropping the field instead would leave
`XCTAssertFalse(perCase.isEmpty)` as the only thing between the app and a vacuous pass.

WHERE THE DIVERGENCE COMES FROM, AND WHAT IT IS NOT
--------------------------------------------------
Historical, and kept because it is the reason the app's preview is shaped the way it is. It was
written when the tone case sat at roughly 36 code values; the Bench was later reconciled and the
committed tolerances are small. Six models were fitted against ffmpeg's own recorded output over
this probe, and none of these is the cause:

  - the SPACE. Rewriting the Bench to convert to luma and chroma, curve the luma, and clip once at
    the end changes nothing at all: adding one luma delta to R, G and B is algebraically identical
    to curving Y while holding Cb and Cr, because the channel differences are preserved either way.
  - the CLIPPING POINT. Same reason. Both clip each channel to 0..255 in the end.
  - the ORDER. Moving saturation ahead of warmth, which is the renderer's order, moves the trims
    case from 6.31 to 5.35 and leaves the tone case untouched.
  - the MATRIX. 709 fits better than 601 (35.75 against 39.01) and better than 2020. So the
    conversion is 709, as tagged.
  - the RANGE. Full range fits at 35.75 against 46.50 for limited, which corroborates the ramp
    measurement independently.
  - WHICH PLANE IS CURVED. Curving chroma instead of luma is far worse, 117 against 36, so
    mergeplanes does map the way its documentation says.

Two more were ruled out afterwards, and one fact was established that makes the rest tractable.

  - a NON-709 LUMA of any kind. The shift ffmpeg applies is uniform across the three channels to
    within 0.004 code values, so it really is "curve one value, shift everything by the delta".
    But no linear combination of R, G and B explains which value: a least-squares fit over 357
    unclipped patches lands on 709's own weights and still leaves a 32-code-value residual.
  - a LINEAR-LIGHT luma. Linearising before the weighted sum fits the single worst patch almost
    exactly, which is how it got tested, and is worse everywhere else: 42 against 36 on the tone
    case. A coincidence, not a cause.

THE FACT THAT MATTERS, and the minimal reproduction for whoever picks this up. The divergence is
not an artefact of the probe, the tiling or the sample offsets: render one flat 8x8 patch of
242.9/55.4/64.8 through `grade_chain` with the shipped tone curve, no look, saturation 1, warmth 0,
and ffmpeg shifts every channel by -31.90. That colour's 709 luma is 95.9, and the curve at 95.9
gives -60.67. A near-neutral patch in the same render agrees with the curve to 0.01. So the effect
is real, deterministic, reproducible on a single pixel, and grows with saturation — the eight worst
patches have saturation 0.55 to 0.83 and the eight best 0.02 to 0.05.

Whatever is happening lives inside ffmpeg's own 10-bit plane handling between `format=yuv444p10le`,
`lut1d` and `mergeplanes`. Reading that source is the next step, not fitting another model: seven
have been fitted and the honest summary is that the shape of the answer is not a colour-space
choice.

One thing the same experiment settled positively: ffmpeg's colorbalance is level-weighted, not a
flat offset. Weighting warmth by the midtone ramp moves the warm-only case from 31.6 to 22.4 code
values, and the Bench's flat offset is wrong everywhere except the midtones. It is not committed,
because the same change moves negative-black the wrong way, from 36.4 to 40.4 — the weighting is
evidently not symmetric in the sign of the move, and guessing again without reading ffmpeg's source
would be another round of this.

THE DECISION THIS MEASUREMENT PRODUCED is in docs/adr/0009: the app's preview is the render, and
no GPU tier is built until the divergence above has a cause. The gate for a second implementation
of the image is this harness, and a harness that measures an unexplained gap cannot hold one.

WHAT THIS DOES NOT COVER YET. The input-correction stage (scripts/make-correct-lut.py) has no case
here, so nothing is measured against it. Giving it one means the probe has to become an Apple Log
probe, because that stage runs before the conversion and a Rec.709 probe cannot exercise it.

FRESHNESS IS BY CONTENT. The golden records a fingerprint of the chain string that produced it, and
a chain edit that outruns its golden fails BY NAME. mtime cannot work: git does not preserve it, so
on a fresh clone the committed golden always lands newer than lib.sh.

THE GOLDEN IS WRITTEN FROM HERE, not by a separate generator, so its format has exactly one home. A
reader and a writer in different files is the two-copies-one-edited failure this project keeps
finding.

Usage:
  tests/grade-parity.py               check the golden against the chain and the probe
  tests/grade-parity.py --regenerate  re-render the probe and the golden (needs ffmpeg)
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from collections import namedtuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "scripts", "make-tone-lut.py")
LIB = os.path.join(ROOT, "scripts", "lib.sh")
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
PROBE = os.path.join(FIXTURES, "grade-probe.png")
GOLDEN = os.path.join(FIXTURES, "grade-golden.json")
LOOK = os.path.join(ROOT, "look.json")

# Two calibration runs, then the shipped look, then the corners — a divergence is most likely to
# hide in a branch the shipped values never take, which is why the extremes are here at all.
#
# NEITHER CALIBRATION RUN IS A LOOK. Both neutralise the curve, the saturation and the warmth, and
# they differ only in which 3D LUT sits at the head of the chain:
#
#   floor      no look filter at all. What this moves is the RGB/YUV round-trip ffmpeg performs
#              side of the chain — error that belongs to colour conversion, not to anyone's maths.
#              Every other number here has to be read on top of it.
#   post-look  the real Portra cube. This was the Bench's documented input (post-CST, post-look),
#              so it is what the Bench's maths was fed; LiveGradeTests now reads it the same way.
#
# The first version of this file used one run for both jobs and reported a 189-code-value "floor",
# which was the look LUT's own effect rather than any conversion error. Two runs, two questions.
Case = namedtuple("Case", "name params sat warm look")
NEUTRAL_TONE = dict(gamma=1.00, pivot=0.50, contrast=1.00, toe=0.00, shoulder=0.00, black=0.000)

# Written out rather than read from look.json, because the golden records each case at the values
# it was rendered at and a look re-tune must not silently re-point these cases. check() asserts
# they still equal look.json, so a re-tune fails by name instead of leaving `shipped` stale.
SHIPPED_TONE = dict(gamma=2.02, pivot=0.39, contrast=1.09, toe=0.00, shoulder=0.10, black=0.025)
SHIPPED_SAT, SHIPPED_WARM = 1.27, 0.005

CASES = [
    Case("floor", NEUTRAL_TONE, 1.00, 0.000, "none"),
    Case("post-look", NEUTRAL_TONE, 1.00, 0.000, "real"),
    # The shipped look, then the same look split in half, so the divergence can be attributed
    # rather than just reported. `tone-only` moves the curve with the trims neutral, which isolates
    # the curve's APPLICATION — ffmpeg curves the Y plane in YUV, the Bench curved an RGB-derived
    # luma in full range. `trims-only` moves saturation and warmth with the curve neutral, which
    # isolates hue=s= against an RGB saturation and colorbalance against a flat offset.
    Case("shipped", SHIPPED_TONE, SHIPPED_SAT, SHIPPED_WARM, "real"),
    Case("tone-only", SHIPPED_TONE, 1.00, 0.000, "real"),
    Case("trims-only", NEUTRAL_TONE, SHIPPED_SAT, SHIPPED_WARM, "real"),
    # One trim each, at a value large enough to see on its own. Without these the guard is
    # insensitive to a small trim regression: the shipped look's divergence is dominated by the
    # tone stage, so deleting the Bench's warmth line entirely hid underneath it and left
    # `shipped` green. Found by mutation.
    Case("warm-only", NEUTRAL_TONE, 1.00, 0.120, "real"),
    Case("sat-only", NEUTRAL_TONE, 1.60, 0.000, "real"),
    Case("extreme", dict(gamma=2.60, pivot=0.25, contrast=1.80, toe=0.80, shoulder=0.80,
                         black=0.080), 1.60, 0.120, "real"),
    Case("negative-black", dict(gamma=1.50, pivot=0.65, contrast=0.80, toe=0.40, shoulder=0.00,
                                black=-0.080), 0.60, -0.120, "real"),
    Case("midrange", dict(gamma=1.85, pivot=0.45, contrast=1.12, toe=0.30, shoulder=0.35,
                          black=0.000), 1.12, 0.000, "real"),
]
CALIBRATION = ("floor", "post-look")

# --- the probe ----------------------------------------------------------------
# Patches rather than a photograph, because a photograph's coverage is whatever happened to be in
# frame. Three groups, each answering a different question:
#
#   cube    a 5-step grid over the RGB cube. Coarse deliberately: the trims are smooth functions
#           of colour, so a denser grid would cost golden size without adding a failure mode.
#   ramp    256 neutral steps. The tone curve lives here, and the curve is the part with branches
#           in it, so it gets the dense coverage.
#   refs    the four references the Bench measured, taken from its SAMPLERS swatches rather than
#           invented here (app/Sources/GradeKit/Scopes.swift carries them now): RAL 1021 plate
#           yellow, RAL 3020 traffic red, RAL 5017 traffic blue and a near-neutral. Saturated
#           colour is where a per-channel trim misbehaves.
CUBE_STEPS = 5
RAMP_STEPS = 256
REFS = [(0xf3, 0xc3, 0x00), (0xcc, 0x06, 0x05), (0x06, 0x39, 0x71), (0x8b, 0x8f, 0x96)]
PATCH = 4          # pixels per patch side; the reader samples the centre
RGB48_BYTES = 6    # bytes per pixel in an rgb48le frame: three 16-bit channels
GRID_W = 20        # patches per row


def probe_patches():
    """The probe's patch values, 16-bit, in layout order. One source of truth for both the image
    and the golden's input column."""
    out = []
    q = CUBE_STEPS - 1
    for r in range(CUBE_STEPS):
        for g in range(CUBE_STEPS):
            for b in range(CUBE_STEPS):
                out.append(tuple(int(round(c * 65535 / q)) for c in (r, g, b)))
    for i in range(RAMP_STEPS):
        v = int(round(i * 65535 / (RAMP_STEPS - 1)))
        out.append((v, v, v))
    for r, g, b in REFS:
        out.append(tuple(int(round(c * 65535 / 255)) for c in (r, g, b)))
    return out


def probe_size(n):
    rows = (n + GRID_W - 1) // GRID_W
    return GRID_W * PATCH, rows * PATCH


def probe_png_bytes():
    """A 16-bit PNG, written here rather than through ffmpeg so the probe carries no swscale
    behaviour of its own — what is being measured must not also be in the ruler."""
    patches = probe_patches()
    w, h = probe_size(len(patches))
    rows = []
    for y in range(h):
        row = bytearray(b"\x00")           # filter type 0
        for x in range(w):
            i = (y // PATCH) * GRID_W + (x // PATCH)
            r, g, b = patches[i] if i < len(patches) else (0, 0, 0)
            row += struct.pack(">HHH", r, g, b)
        rows.append(bytes(row))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack(">IIBBBBB", w, h, 16, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def sample_offsets(n):
    """Byte offset of each patch's centre pixel within an rgb48le raw frame."""
    w, _ = probe_size(n)
    off = []
    for i in range(n):
        px = (i % GRID_W) * PATCH + PATCH // 2
        py = (i // GRID_W) * PATCH + PATCH // 2
        off.append((py * w + px) * RGB48_BYTES)
    return off


# --- the chain, out of lib.sh -------------------------------------------------
def chain_string(tone, sat, warm, look="real"):
    """The production chain, out of lib.sh.

    `look` is "real" for look.json's own choice, which grade_chain loads itself when nothing is
    set, or anything resolve_look_lut accepts — "none" being the one the floor run uses. Any look
    other than "real" also means no print: the floor run measures the round trip with no cube in
    it, and a print named in look.json would otherwise arrive through the same unset-means-ask
    rule. That rule exists because a chain read out of lib.sh once came back with NO look filter
    at all; the fingerprint guard is what caught it, which is why it hashes the chain."""
    r = subprocess.run(["bash", "-c",
                        'set -euo pipefail; source "$1"; '
                        'if [ "$5" != "real" ]; then '
                        '  LOOK_LUT="$(resolve_look_lut "$5" "$6")"; PRINT_LUT=""; fi; '
                        'grade_chain "$2" "$3" "$4"',
                        "_", LIB, tone, sat, warm, look, ROOT],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("could not read grade_chain out of lib.sh:\n" + r.stderr)
    return r.stdout.strip()


def chain_fingerprint():
    """Hash the chain's SHAPE, with the parameters and the absolute LUT path tokenised out. The
    look LUT's path contains the checkout location, so hashing it raw would make every clone
    disagree, and the parameters vary per case and are recorded separately anyway."""
    s = chain_string("<TONE>", "<SAT>", "<WARM>", "real").replace(ROOT, "<ROOT>")
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


# --- ffmpeg, the oracle -------------------------------------------------------
def render_case(params, sat, warm, probe_path, look="real"):
    with tempfile.NamedTemporaryFile(suffix=".cube", delete=False) as f:
        cube = f.name
    try:
        cmd = [sys.executable, GEN, cube]
        for k, v in params.items():
            cmd += ["--" + k, str(v)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("make-tone-lut.py failed:\n" + r.stderr)
        # TELL ffmpeg WHAT THE PROBE IS. An untagged RGB input is converted to YUV with BT.601 at
        # LIMITED range — swscale's default — while the Bench modelled 709 full. Measured on one
        # patch: ffmpeg's luma plane held 112.67 where 709 full says 95.94 and 601 limited says
        # 112.65, and its chroma matched 601 limited to two decimal places. That conversion is not
        # one production performs: its source arrives already in YUV. So the probe is tagged, with
        # the same setparams the engine uses on its own synthesised branches, and what is left to
        # measure is the maths rather than an artefact of an untagged PNG.
        tag = "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=pc,"
        # A `look` of "none" omits the look filter rather than interpolating an identity cube
        # through it, which is what the engine itself now does — and it measures the round trip
        # without a lookup in it at all, which is what the floor case was always trying to isolate.
        graph = "[0:v]%s%s,format=rgb48le[o]" % (tag, chain_string(cube, str(sat), str(warm), look))
        r = subprocess.run(["ffmpeg", "-v", "error", "-i", probe_path,
                            "-filter_complex", graph, "-map", "[o]",
                            "-f", "rawvideo", "-pix_fmt", "rgb48le", "-"],
                           capture_output=True)
        if r.returncode != 0:
            sys.exit("ffmpeg failed on the probe:\n" + r.stderr.decode("utf-8", "replace"))
        raw = r.stdout
        return [list(struct.unpack_from("<HHH", raw, off))
                for off in sample_offsets(len(probe_patches()))]
    finally:
        os.unlink(cube)


def to8(v):
    return [c * 255.0 / 65535.0 for c in v]


def worst_delta(a_rows, b_rows):
    w = 0.0
    for a, b in zip(a_rows, b_rows):
        for x, y in zip(a, b):
            w = max(w, abs(x - y))
    return w


# --- regenerate ---------------------------------------------------------------
def regenerate():
    if not os.path.isdir(FIXTURES):
        os.makedirs(FIXTURES)
    png = probe_png_bytes()
    with open(PROBE, "wb") as f:
        f.write(png)
    patches = probe_patches()
    w, h = probe_size(len(patches))
    print("probe   %dx%d, %d patches, %d bytes" % (w, h, len(patches), len(png)))

    cases = []
    for case in CASES:
        out = render_case(case.params, case.sat, case.warm, PROBE, case.look)
        cases.append(dict(name=case.name, params=case.params, saturation=case.sat,
                          warmth=case.warm, look=case.look, output=out))
        print("render  %-15s %d samples (%s look LUT)" % (case.name, len(out), case.look))

    by = {c["name"]: c for c in cases}

    # CARRIED FORWARD, NOT MEASURED HERE. These numbers are how far an approximation of the chain
    # sits from ffmpeg, and the only approximation left is Swift's `LiveGrade`, which this file
    # cannot run — the JavaScript one went with the Bench. Inventing them is worse than copying
    # them and dropping them is worse still: LiveGradeTests reads this field, and an absent one
    # leaves `XCTAssertFalse(perCase.isEmpty)` as the only guard against a vacuous pass.
    worst = {}
    if os.path.exists(GOLDEN):
        with open(GOLDEN) as f:
            worst = json.load(f)["tolerances"].get("grade_worst_by_case", {})
    worst = {k: v for k, v in worst.items() if k not in CALIBRATION}

    floor = worst_delta([to8(v) for v in by["floor"]["output"]], [to8(v) for v in patches])

    golden = {
        "_comment": [
            "Generated by tests/grade-parity.py --regenerate. Do not hand-edit: the harness that",
            "reads this file is the one that writes it, so an edited value is a claim nothing",
            "produced.",
            "",
            "chain_fingerprint hashes grade_chain's SHAPE, with the parameters and the checkout",
            "path tokenised out. It is how freshness is decided: a chain edit that outruns this",
            "file fails by name. mtime cannot work, because git does not preserve it.",
            "",
            "output holds ffmpeg's own result per probe patch, 16-bit RGB. That is what makes",
            "ffmpeg the oracle rather than anyone's transcription of it.",
        ],
        "chain_fingerprint": chain_fingerprint(),
        "probe": {
            "sha256": hashlib.sha256(png).hexdigest(),
            "patch": PATCH, "grid_w": GRID_W,
            "cube_steps": CUBE_STEPS, "ramp_steps": RAMP_STEPS, "refs": len(REFS),
        },
        "tolerances": {
            "conversion_floor_code_values": round(floor, 3),
            "_floor_why": [
                "What the `floor` case moves: identity look cube, identity curve, saturation 1,",
                "warmth 0. So this is the RGB/YUV round-trip ffmpeg performs either side of the",
                "chain, not anyone's maths, and every other number here has to be read on top of",
                "it. Measured with two separate runs because measuring it with one — the real look",
                "cube and a neutral curve — reported the look LUT's own effect as a 189-code-value",
                "conversion error.",
            ],
            "grade_code_values": max(worst.values()) if worst else 0.0,
            "_grade_why": [
                "MEASURED, not chosen. A tolerance picked to make a test pass leaves a guard that",
                "cannot fail, so this records what an approximation of the chain actually costs.",
                "",
                "CARRIED FORWARD BY --regenerate, NOT RE-MEASURED. These were measured against the",
                "browser Bench's JavaScript, which has since been deleted (docs/adr/0007). The only",
                "approximation left is Swift's LiveGrade, and tests/grade-parity.py cannot run it,",
                "so it copies these numbers rather than inventing or dropping them. A CHAIN CHANGE",
                "MAKES THEM STALE: re-measure in app/Tests/GradeKitTests/LiveGradeTests.swift and",
                "write the new numbers in deliberately.",
                "",
                "WHERE IT COMES FROM, and it is not where it was assumed to be. Decomposed on the",
                "shipped look, worst case in 8-bit code values:",
                "",
                "                 cube    ramp    refs",
                "  tone-only     36.21    2.49   28.69",
                "  trims-only     6.32    2.83    5.08",
                "  shipped       28.81    3.97   23.28",
                "",
                "So the trims are the SMALL half. The Bench's saturation and warmth stand-ins cost",
                "about six code values, and the two partly cancel, which is why `shipped` measures",
                "lower than `tone-only` alone.",
                "",
                "The large half is the tone stage's APPLICATION. On neutral tones the Bench is",
                "faithful to within 2.5 code values, so the curve and its domain are right — and a",
                "separate experiment confirmed ffmpeg curves a FULL-range luma, not a 16-235 one",
                "(the limited-range model measured 16.8 against 2.49). What diverges is saturated",
                "colour: the Bench subtracts one luma delta from all three channels, which drives",
                "already-low channels below zero and clamps them, while the renderer curves the Y",
                "plane and merges the ORIGINAL chroma back. The worst patch, a saturated orange,",
                "goes to 187.7/0.0/0.0 in the Bench against 223.9/25.8/0.0 in the renderer.",
                "",
                "That is ADR 0003 seen from the other side: an equal RGB offset is not what",
                "mergeplanes=0x001112 does. The consequence for the app is concrete — its Metal",
                "preview must curve Y and keep CbCr, not shift RGB — and it is a requirement",
                "measured here rather than assumed.",
            ],
            "grade_worst_by_case": worst,
            "grade_margin_code_values": 0.5,
            "_margin_why": [
                "Each case is asserted against its own number above, plus this margin. Both sides",
                "are deterministic — one ffmpeg build, one Swift build — so the margin only",
                "absorbs floating-point jitter. A single global tolerance was the alternative and",
                "it would have let the shipped look drift by the extreme case's hundred code",
                "values while still reporting green.",
            ],
        },
        "cases": cases,
    }
    with open(GOLDEN, "w") as f:
        json.dump(golden, f, indent=1)
        f.write("\n")
    print("\nfloor   %.3f code values (RGB/YUV round-trip)" % floor)
    print("wrote   %s (%d bytes)" % (os.path.relpath(GOLDEN, ROOT), os.path.getsize(GOLDEN)))
    if worst:
        print("\nCARRIED FORWARD, NOT MEASURED: grade_worst_by_case (%d cases, worst %.3f).\n"
              "  ffmpeg's output above is freshly rendered; those tolerances are not. They measure\n"
              "  an approximation of the chain, and the only one left is Swift's LiveGrade, which\n"
              "  this harness cannot run.\n"
              "  IF YOU CHANGED THE CHAIN THEY ARE NOW STALE. Re-measure with\n"
              "    swift test --package-path app --filter LiveGradeTests\n"
              "  and write the new numbers into the golden deliberately."
              % (len(worst), max(worst.values())), file=sys.stderr)
    else:
        print("\nNO TOLERANCES CARRIED FORWARD — there was no golden to copy them from.\n"
              "  LiveGradeTests will fail on an empty grade_worst_by_case, which is the intended\n"
              "  direction: measure them there and write them in.", file=sys.stderr)


# --- check --------------------------------------------------------------------
def shipped_case_drift():
    """Differences between the cases that claim to be the shipped look and look.json."""
    look = json.load(open(os.path.join(ROOT, "look.json")))
    tone = {k: float(v) for k, v in look["tone"].items()}
    sat, warm = float(look["colour"]["saturation"]), float(look["colour"]["warmth"])
    fails = []
    for name, params, case_sat, case_warm, _look in CASES:
        if name not in ("shipped", "tone-only"):
            continue
        if {k: float(v) for k, v in params.items()} != tone:
            fails.append("case %s's tone is not look.json's tone" % name)
        if name == "shipped" and (case_sat, case_warm) != (sat, warm):
            fails.append("case shipped's saturation and warmth are not look.json's")
    return fails


def check():
    if not os.path.exists(GOLDEN):
        sys.exit("no golden at %s — run tests/grade-parity.py --regenerate" % GOLDEN)
    with open(GOLDEN) as f:
        golden = json.load(f)
    fails = []

    # 0. The shipped cases are look.json's look. Checked before freshness so a re-tune fails by
    #    this name even when the golden is also stale for another reason.
    with open(LOOK) as f:
        look_json = json.load(f)
    drift = []
    if look_json["tone"] != SHIPPED_TONE:
        drift.append("tone: look.json %s, harness %s" % (look_json["tone"], SHIPPED_TONE))
    if (look_json["colour"]["saturation"], look_json["colour"]["warmth"]) != (SHIPPED_SAT,
                                                                             SHIPPED_WARM):
        drift.append("colour: look.json %s, harness saturation=%s warmth=%s"
                     % (look_json["colour"], SHIPPED_SAT, SHIPPED_WARM))
    if drift:
        print("SHIPPED CASE IS NOT THE SHIPPED LOOK\n"
              "  The `shipped` and `tone-only` cases claim to be look.json's look and are not, so\n"
              "  the app would be held to a look nothing ships. Update SHIPPED_* in\n"
              "  tests/grade-parity.py, re-run --regenerate, and re-measure in LiveGradeTests.\n  "
              + "\n  ".join(drift), file=sys.stderr)
        return 1

    # 1. Freshness, by content: the guard that stops a chain edit shipping with a golden that
    #    describes the chain it replaced.
    now = chain_fingerprint()
    if now != golden["chain_fingerprint"]:
        print("STALE GOLDEN\n"
              "  grade_chain in scripts/lib.sh no longer matches the chain this golden was\n"
              "  generated from.\n    golden: %s\n    lib.sh: %s\n"
              "  If the change was intended, re-run tests/grade-parity.py --regenerate and say in\n"
              "  the commit what moved and why." % (golden["chain_fingerprint"][:16], now[:16]),
              file=sys.stderr)
        return 1

    # 2. The probe itself, by content, for the same reason.
    if os.path.exists(PROBE):
        with open(PROBE, "rb") as f:
            have = hashlib.sha256(f.read()).hexdigest()
        if have != golden["probe"]["sha256"]:
            print("the probe image does not match the golden measured on it", file=sys.stderr)
            return 1

    # 3. The golden still answers every case this harness declares, with the parameters it
    #    declares them at. A case added to CASES without a regenerate would otherwise sit there
    #    unrendered, and LiveGradeTests skips a case it cannot find — so the new case would read
    #    as covered while being measured against nothing.
    recorded = {c["name"]: c for c in golden["cases"]}
    for case in CASES:
        c = recorded.get(case.name)
        if c is None:
            fails.append("case %s is declared here but absent from the golden" % case.name)
            continue
        if (c["params"] != case.params or c["saturation"] != case.sat
                or c["warmth"] != case.warm or c["look"] != case.look):
            fails.append("case %s is recorded at different parameters than it is declared at"
                         % case.name)
        elif not c.get("output"):
            fails.append("case %s has no recorded ffmpeg output" % case.name)

    # 3b. The cases NAMED for the shipped look are at the shipped look. They are literals so that a
    #    re-tune cannot quietly move what the golden recorded, and nothing tied them to look.json:
    #    after a re-tune `shipped` would stay green while measuring a look nothing ships. Loud
    #    instead — update the case, regenerate, and say so in the commit.
    fails += shipped_case_drift()

    # 4. Every non-calibration case carries a tolerance. This is the guard on the field
    #    --regenerate carries forward rather than measures: LiveGradeTests reads it, and a case
    #    with no entry is one that test silently skips. Losing one is how the app's only parity
    #    gate would go quiet without anything going red.
    per_case = golden["tolerances"].get("grade_worst_by_case", {})
    for case in CASES:
        if case.name in CALIBRATION:
            continue
        if case.name not in per_case:
            fails.append("case %s has no tolerance in grade_worst_by_case, so LiveGradeTests "
                         "will skip it" % case.name)
    for name in per_case:
        if name not in {c.name for c in CASES}:
            fails.append("grade_worst_by_case carries %s, which is no longer a case" % name)

    if fails:
        print("\nThe golden no longer describes what this harness measures, so the numbers the\n"
              "app is held to are not the numbers anything produced. Re-run --regenerate, or fix\n"
              "the case list, then re-run.\n  " + "\n  ".join(fails), file=sys.stderr)
        return 1
    print("\nGolden fresh against the chain and the probe. %d cases recorded, %d with tolerances,\n"
          "floor %.3f code values. The per-pixel comparison runs in LiveGradeTests."
          % (len(golden["cases"]), len(per_case),
             golden["tolerances"]["conversion_floor_code_values"]))
    return 0


if __name__ == "__main__":
    if "--regenerate" in sys.argv[1:]:
        regenerate()
        sys.exit(0)
    sys.exit(check())
