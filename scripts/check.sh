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
FAST=0
for a in "$@"; do
	case "$a" in
		--allow-skips) ALLOW_SKIPS=1;;
		--conformance) CONFORMANCE=1;;
		--fast) FAST=1;;
		*) echo "unknown option: $a" >&2; exit 2;;
	esac
done
SKIPPED=""

# --fast is for iterating, and the full run stays the DEFAULT. This is the command CLAUDE.md says
# to trust, so a default that quietly ran less would bring back the "green but tested nothing"
# failure the missing-tool rule below exists for. What --fast leaves out is named at the end.
#
# The Swift classes left out are the ones that render real footage through the engine. Their
# measured cost, and that of the bats tests tagged `slow`, is in
# docs/adr/0013_A_PARALLEL_SUITE_WITH_A_FAST_TIER.md. Re-measure rather than guess before adding
# to this list.
SLOW_SWIFT='LiveChainTests|EndToEndTests|DeliveryTests|PreviewRendererTests|ClipListTests'

# Parallel runs lose one signal: `swift test --parallel` reports a skipped test as passed, where
# the serial run printed "N tests skipped". Nearly every skip in this suite means missing footage
# or Apple's cube, both gitignored, so the absence is checked directly rather than left to be
# inferred from a count nobody reads.
MISSING_MEDIA=""
ls src/*.mov >/dev/null 2>&1 || MISSING_MEDIA="$MISSING_MEDIA src/*.mov"
[ -f luts/apple/AppleLogToRec709-v1.0.cube ] || MISSING_MEDIA="$MISSING_MEDIA luts/apple/AppleLogToRec709-v1.0.cube"
if [ -n "$MISSING_MEDIA" ]; then
	echo "NOTE — missing:$MISSING_MEDIA"
	echo "  Every test that needs real footage or Apple's conversion will skip, and in the parallel"
	echo "  Swift run a skip reads as a pass. Green here does not cover the render."
	echo
fi

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
	# --parallel runs each test class in its own process: 104s serially, 61s parallel, measured on
	# this 8-thread i7. Every render test works in its own UUID temp directory, which is what makes
	# that safe.
	# Captured rather than piped to `tail`: under --parallel the last lines are only the last tests
	# started, so a tail showed neither the count nor a failing assertion.
	swift_args=(--package-path app --parallel)
	[ "$FAST" = "1" ] && swift_args+=(--skip "$SLOW_SWIFT")
	[ "$FAST" = "1" ] || swift build --package-path app 2>&1 | tail -2
	swift_log=$(mktemp -t check-swift)
	if swift test "${swift_args[@]}" > "$swift_log" 2>&1; then
		echo "$(grep -c '^\[[0-9]*/[0-9]*\] Testing' "$swift_log") tests passed"
		rm -f "$swift_log"
	else
		grep -E 'error:|failed|Fatal' "$swift_log" || tail -30 "$swift_log"
		echo "swift test FAILED — full log: $swift_log" >&2
		exit 1
	fi
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
	# Tags are explained at the top of tests/lib.bats. The serial pass runs ALONGSIDE the parallel
	# one, not after it: serial tests conflict with each other, not with the rest, and the release
	# build among them is the single longest test in the suite.
	# Without GNU parallel, bats cannot use -j; everything then runs in one serial pass. That is
	# the same coverage, only slower, so it is not recorded as a skip.
	# ONE --filter-tags per call, with the conditions comma-joined. bats ANDs within a list but ORs
	# separate --filter-tags flags, so `--filter-tags '!slow' --filter-tags serial` would run every
	# test that is fast OR serial.
	slow_tag=""
	[ "$FAST" = "1" ] && slow_tag='!slow,'
	if command -v parallel >/dev/null; then
		serial_log=$(mktemp -t check-bats-serial)
		bats --filter-tags "${slow_tag}serial" tests/ > "$serial_log" 2>&1 &
		serial_pid=$!
		bats_rc=0
		bats -j "$(sysctl -n hw.ncpu)" --filter-tags "${slow_tag}!serial" tests/ || bats_rc=1
		wait "$serial_pid" || bats_rc=1
		echo "-- serial --"
		cat "$serial_log"
		rm -f "$serial_log"
		[ "$bats_rc" = "0" ] || exit 1
	elif [ "$FAST" = "1" ]; then
		echo "(GNU parallel not installed: running bats serially)"
		bats --filter-tags '!slow' tests/
	else
		echo "(GNU parallel not installed: running bats serially)"
		bats tests/
	fi
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

if [ "$FAST" = "1" ]; then
	echo
	echo "FAST RUN (--fast): did not run the bats tests tagged slow, the Swift classes"
	echo "  ${SLOW_SWIFT//|/, }, or swift build. Not a pass for a commit: run ./scripts/check.sh."
fi
