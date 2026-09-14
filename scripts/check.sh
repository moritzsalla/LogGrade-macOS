#!/bin/bash
# Lint + test the pipeline. Run before trusting any change to scripts/.
#
# Neither tool is a substitute for the other, and this pipeline has proof:
#   - shellcheck found ZERO issues in scripts that contained two shipped, load-bearing bugs.
#   - bats found both, because it runs the code on the actual interpreter (bash 3.2 on macOS,
#     whose empty-array handling under `set -u` differs from every modern bash).
# Run both.
#
# A MISSING TOOL IS A FAILURE, NOT A PASS. This is the command CLAUDE.md tells you to trust, and
# it used to exit 0 having skipped shellcheck and the grade parity check — so "green" could mean
# "ran the bats suite and nothing else". Each skip is now recorded and the run exits non-zero at
# the end, naming what did not run. Pass --allow-skips when you genuinely want a partial run, e.g.
# iterating on one bats test without node installed.
#
# --conformance additionally renders one clip through this fork AND through the frozen precursor
# and asserts the bytes match (tests/conformance.sh). It is opt-in because it costs minutes, not
# seconds; it is the check to run before trusting a change to the chain itself.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ALLOW_SKIPS=0
CONFORMANCE=0
for a in "$@"; do
	case "$a" in
		--allow-skips) ALLOW_SKIPS=1;;
		--conformance) CONFORMANCE=1;;
		*) echo "unknown option: $a" >&2; exit 2;;
	esac
done
SKIPPED=""

echo "== shellcheck =="
if command -v shellcheck >/dev/null; then
	# Lint by SHEBANG, not by extension — a script with no .sh suffix was silently excluded by a
	# `*.sh` glob for its whole existence.
	# `mapfile` is bash 4.0+; macOS ships 3.2, where it silently does nothing and the check
	# stops testing anything. Use a plain loop.
	# tests/ is included because a shell script there is production code too: conformance.sh is the
	# guard that the fork still renders what the precursor rendered, and it was unlinted for exactly
	# as long as this loop only looked in scripts/.
	( targets=""
	  for f in scripts/* tests/*; do
	    [ -f "$f" ] || continue
	    head -1 "$f" | grep -q '^#!/.*bash' && targets="$targets $f"
	  done
	  # shellcheck disable=SC2086
	  shellcheck -x -s bash $targets && echo "clean:$targets" )
else
	echo "shellcheck NOT INSTALLED (binary: github.com/koalaman/shellcheck/releases)"
	SKIPPED="$SKIPPED shellcheck"
fi

echo
echo "== grade golden (ffmpeg's recorded output, against the chain and the probe) =="
# It used to gate on node, because this check ran the browser Bench's JavaScript. The Bench is
# gone (docs/adr/0007) and the per-pixel comparison moved to LiveGradeTests, which the swift block
# below runs. What is left here is the golden itself: fresh against grade_chain, matching the probe
# it was measured on, and still carrying a tolerance for every case — that last one is what keeps
# LiveGradeTests from silently skipping a case and reading as coverage.
if command -v python3 >/dev/null; then
	./tests/grade-parity.py
else
	echo "python3 NOT INSTALLED. This is the check that catches a golden describing a chain that"
	echo "no longer exists, which would leave the app's parity gate measuring nothing."
	SKIPPED="$SKIPPED grade-golden"
fi

echo
echo "== swift (GradeKit) =="
# The app's package is part of this repo, so the one command that checks the repo has to check it.
# A missing toolchain is a SKIP under the same contract as every other tool here: recorded, and
# fatal at the end unless --allow-skips. Xcode 15.2 is the newest for this machine's macOS, which
# is why Package.swift pins the tools version rather than tracking whatever is installed.
if command -v swift >/dev/null; then
	swift build --package-path app 2>&1 | tail -2
	swift test --package-path app 2>&1 | tail -3
else
	echo "swift NOT INSTALLED (needs Xcode, and its licence accepted)"
	SKIPPED="$SKIPPED swift"
fi

echo
echo "== conformance (this fork vs the frozen precursor) =="
# OPT-IN, and deliberately not counted as a skip. The missing-tool rule above exists because an
# absent tool silently removed coverage; choosing not to pass --conformance is not silent, and this
# check renders through two engines, which takes minutes rather than seconds. Run it before
# trusting any change to the chain in scripts/lib.sh.
if [ "$CONFORMANCE" = "1" ]; then
	set +e; ./tests/conformance.sh; rc=$?; set -e
	case "$rc" in
		0) ;;
		3) SKIPPED="$SKIPPED conformance";;
		*) exit "$rc";;
	esac
else
	echo "not run — opt in with --conformance. It renders through both engines, so it costs minutes."
fi

echo
echo "== bats =="
if command -v bats >/dev/null; then
	bats tests/
else
	echo "bats NOT INSTALLED (github.com/bats-core/bats-core, install.sh ~/.local)"
	SKIPPED="$SKIPPED bats"
fi

if [ -n "$SKIPPED" ]; then
	echo
	if [ "$ALLOW_SKIPS" = "1" ]; then
		echo "PARTIAL RUN (--allow-skips): did not run:$SKIPPED"
	else
		echo "INCOMPLETE — did not run:$SKIPPED" >&2
		echo "  Do not read this as a pass. Install the missing tool, or re-run with" >&2
		echo "  ./scripts/check.sh --allow-skips to accept a partial run deliberately." >&2
		exit 1
	fi
fi
