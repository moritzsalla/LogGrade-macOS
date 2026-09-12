#!/usr/bin/env python3
"""
Assert the Grade Bench's curve maths still matches make-tone-lut.py.

WHY THIS IS THE MOST IMPORTANT TEST IN THE PROJECT
--------------------------------------------------
The Bench (bench/index.html) reimplements the tone curve in JavaScript so it can preview a grade
at interactive speed. The pipeline generates the real LUT in Python. They are two implementations
of one formula, and the ENTIRE grading workflow rests on them agreeing: a person grades by eye in
the browser, sends the parameters, and the renderer applies them. If the two drift, the preview
silently stops predicting the render — no error, no warning, just a grade that looks right in the
Bench and wrong in the output, with nothing to point at.

Nothing else in the project catches this. Both halves keep working perfectly; only their agreement
breaks. Both files carry a "keep them in step" comment, which is exactly the kind of instruction
that gets read after the divergence rather than before.

HOW IT WORKS
------------
Rather than compare source (which would break on every stylistic edit), this compares BEHAVIOUR:
it generates a real .cube with make-tone-lut.py, extracts the JS functions straight out of the
published HTML, runs them in node over the same inputs, and diffs the two curves.

Testing the generated artifact rather than the Python source also means it covers the .cube
writer, not just the formula.

Usage: tests/curve-parity.py            (exit 0 = in step, 1 = drifted)
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "bench", "index.html")
GEN = os.path.join(ROOT, "scripts", "make-tone-lut.py")

# Parameter sets to compare over. The first is what currently ships; the rest deliberately probe
# the corners — zero toe and shoulder, heavy toe, a pivot at each extreme, a black-point lift —
# because a divergence is most likely to hide in a branch the shipped values never take.
CASES = [
    dict(gamma=2.02, pivot=0.39, contrast=1.09, toe=0.00, shoulder=0.10, black=0.025),
    dict(gamma=1.00, pivot=0.50, contrast=1.00, toe=0.00, shoulder=0.00, black=0.000),
    dict(gamma=2.60, pivot=0.25, contrast=1.80, toe=0.80, shoulder=0.80, black=0.080),
    dict(gamma=1.50, pivot=0.65, contrast=0.80, toe=0.40, shoulder=0.00, black=-0.080),
    dict(gamma=1.85, pivot=0.45, contrast=1.12, toe=0.30, shoulder=0.35, black=0.000),
]

TOLERANCE = 1.0 / 255.0  # one 8-bit code value: below this nothing downstream can see it


def extract_js():
    """Pull `soft` and `curveAt` out of the Bench, verbatim."""
    src = open(BENCH, encoding="utf-8").read()
    out = []
    for name in ("soft", "curveAt"):
        m = re.search(r"function\s+%s\s*\(" % name, src)
        if not m:
            sys.exit("could not find function %s() in %s" % (name, BENCH))
        # walk braces from the function's opening { to its matching close
        start = src.index("{", m.end() - 1)
        depth, i = 0, start
        while i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        out.append(src[m.start():i + 1])
    return "\n".join(out)


def js_curve(params, xs):
    harness = """
%s
var P = %s;
var out = xs_PLACEHOLDER.map(function (x) { return curveAt(x); });
console.log(JSON.stringify(out));
""" % (extract_js(), json.dumps(params))
    harness = harness.replace("xs_PLACEHOLDER", json.dumps(xs))
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(harness)
        path = f.name
    try:
        r = subprocess.run(["node", path], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("node failed:\n" + r.stderr)
        return json.loads(r.stdout)
    finally:
        os.unlink(path)


def py_curve(params, xs):
    """Generate a real .cube and read the curve back out of it."""
    with tempfile.NamedTemporaryFile(suffix=".cube", delete=False) as f:
        cube = f.name
    try:
        cmd = [sys.executable, GEN, cube]
        for k, v in params.items():
            cmd += ["--" + k, str(v)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("make-tone-lut.py failed:\n" + r.stderr)
        vals = []
        for line in open(cube):
            s = line.strip()
            if not s or s.startswith("#") or s.startswith("TITLE") or s.startswith("LUT_"):
                continue
            p = s.split()
            if len(p) == 3:
                vals.append(float(p[0]))
        n = len(vals)
        return [vals[min(n - 1, int(round(x * (n - 1))))] for x in xs]
    finally:
        os.unlink(cube)


def main():
    xs = [i / 256.0 for i in range(257)]
    failures = []
    for case in CASES:
        j = js_curve(case, xs)
        p = py_curve(case, xs)
        worst, worst_x = 0.0, 0.0
        for x, a, b in zip(xs, j, p):
            d = abs(a - b)
            if d > worst:
                worst, worst_x = d, x
        label = " ".join("%s=%g" % (k, v) for k, v in case.items())
        if worst > TOLERANCE:
            failures.append((label, worst, worst_x))
            print("DRIFTED  %s\n         max delta %.5f at x=%.3f (tolerance %.5f)"
                  % (label, worst, worst_x, TOLERANCE))
        else:
            print("in step  %s  (max delta %.6f)" % (label, worst))

    if failures:
        print("\nThe Bench and make-tone-lut.py have diverged. The browser preview no longer\n"
              "predicts what the renderer produces, so any grade sent from it is unreliable\n"
              "until they are reconciled. Fix BOTH, then re-run.", file=sys.stderr)
        return 1
    print("\nAll %d parameter sets agree within one 8-bit code value." % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
