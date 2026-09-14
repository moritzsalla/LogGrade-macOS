#!/usr/bin/env bats
# Tests for scripts/lib.sh — the safety layer.
#
# WHY THIS FILE EXISTS. Every helper in lib.sh was written in response to a real incident, and
# then two of them shipped BROKEN and stayed broken because nothing ever exercised them:
#
#   - `safe_retag` died on every call with "unbound variable" (bash 3.2 + `set -u` + an empty
#     array), silently skipping the retag it exists to perform and leaving masters mistagged.
#   - `verify_bt709` could never pass on ANY file, because ffprobe prints these files' video
#     stream twice and it compared that against a single expected line.
#
# Neither is caught by shellcheck — verified: it reports nothing on the empty-array pattern while
# bash 3.2 fails on it immediately. Only running the code finds them.
#
# So the bar for every test here: delete the guard it covers and the test must go red. A test that
# cannot fail is worse than no test, because it reads as coverage.
#
# Run:  bats tests/

# `run --separate-stderr` is how the event-stream tests assert that stdout carries machine-readable
# output and NOTHING else, which is the contract the app depends on. Flags on `run` arrived in bats
# 1.5, and without this declaration bats warns on every such call rather than failing — so the
# requirement is stated here instead of being discovered from the noise.
bats_require_minimum_version 1.5.0

# TWO TAGS, and scripts/check.sh is what reads them.
#
#   slow    left out by `check.sh --fast`. A test measured at three seconds or more on this machine:
#           the app builds, and renders or probes of real footage. The ranking is in
#           docs/adr/0013_A_PARALLEL_SUITE_WITH_A_FAST_TIER.md. Tag a new test that renders
#           real footage or builds the app.
#   serial  kept out of the parallel pass, because it writes a path another test writes too. The two
#           make-app.sh tests both rebuild dist/LogGrade.app, and one asserts on its contents while
#           the other can be halfway through replacing it. The two 02-grade.sh tests regenerate the
#           REPO's luts/tone/shipped.cube when look.json has moved, and make-tone-lut.py stages that
#           write through one fixed .partial name, so two at once can interleave. Tag any new test
#           that writes outside $BATS_TEST_TMPDIR.
#
# A serial test runs alongside the parallel pass, one at a time, not after it: those tests
# conflict with each other, not with the rest, and waiting for the builds would give back most of
# what the parallel pass saves.

# Fails unless every non-blank line on stdin parses as JSON on its own. python3 rather than a grep
# for braces: a shape test would pass on `{"event":"x",}`.
_json_lines() {  # printf '%s\n' "$output" | _json_lines
	python3 -c '
import json, sys
for i, line in enumerate(sys.stdin.read().splitlines(), 1):
    if not line.strip(): continue
    try: json.loads(line)
    except Exception as e: sys.exit("line %d is not JSON (%s): %s" % (i, e, line))
'
}

# A work dir holding CLIP.mov and a transform measured BEFORE it changed. Stamped rather than
# touched: bash 3.2's -nt compares whole seconds, so same-second files would make a freshness test
# pass for the wrong reason.
_stale_transform() {  # _stale_transform <work>
	mkdir -p "$1/src" "$1/dist/stab"
	cp "$FIXTURES/portrait_tagged.mov" "$1/src/CLIP.mov"
	printf 'measured before the source changed\n' > "$1/dist/stab/CLIP.trf"
	touch -t 202609010000 "$1/dist/stab/CLIP.trf"
	touch -t 202609020000 "$1/src/CLIP.mov"
}

setup_file() {
	command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
	export FIXTURES="$BATS_FILE_TMPDIR/fixtures"
	mkdir -p "$FIXTURES"

	# Tiny synthetic clips — one frame each, so the suite stays fast.
	#
	# 72x128 IS 9:16 EXACTLY, and that is load-bearing rather than arbitrary. These were 64x128,
	# i.e. 1:2, for as long as the 9:16 deliverable took no crop: the delivery chain simply scaled
	# them and quietly changed their aspect. Now that a deliverable is an ASPECT, a source that is
	# not 9:16 gets cropped to reach it — correct, and it would make every fixture here exercise a
	# crop path the real 2160x3840 camera source never takes.
	#
	# How they are tagged is not obvious, and is explained in the builder shared with
	# tests/make-event-fixture.sh.
	source "$BATS_TEST_DIRNAME/fixture-clip.sh"
	# TWO SECONDS, and three distinct luma levels. The exposure probe seeks to 1s, so a 0.1s clip
	# measures nothing at all — which is why the fixtures above cannot exercise the exposure match
	# and every test that uses them passes MATCH=0. These can, and the three levels are what make a
	# median a median rather than "the only value there was".
	# The level is a HEX COLOUR, not `gray@n`: the `@n` suffix is ALPHA, so three clips built that
	# way are three identical greys and a median test over them proves nothing. Caught by a test
	# that asserted the middle clip was the anchor and found all three reading 552.
	_mk_probeable() {  # _mk_probeable <hex grey> <w> <h> <out>
		ffmpeg -y -f lavfi -i "color=c=$1:s=${2}x${3}:d=2:r=24" \
			-frames:v 48 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
			"$4" -v error
	}
	_mk_probeable 0x303030 72 128 "$FIXTURES/probe_dark.mov"
	_mk_probeable 0x808080 72 128 "$FIXTURES/probe_mid.mov"
	_mk_probeable 0xc0c0c0 72 128 "$FIXTURES/probe_bright.mov"
	# Landscape AND measurable, so that a clip which gets skipped still occupies a slot carrying a
	# distinctly different exposure. A skipped clip whose probe came back empty cannot tell a
	# misaligned index from a correct one — the alignment test passed against a removed guard for
	# exactly that reason.
	_mk_probeable 0x303030 128 72 "$FIXTURES/probe_dark_landscape.mov"

	make_tagged_clip 72 128 bt709 bt709 bt709 "$FIXTURES/portrait_tagged.mov"
	make_tagged_clip 128 72 bt709 bt709 bt709 "$FIXTURES/landscape_tagged.mov"
	# Deliberately MIStagged as bt2020 — the "bleached out" state this pipeline exists to prevent.
	make_tagged_clip 72 128 bt2020 bt709 bt2020nc "$FIXTURES/portrait_bt2020.mov"
}

# NOTE ON THE FOOTAGE LOOKUPS BELOW. Each real-footage test finds a clip and skips without one,
# and the lookup ends in `|| true` on purpose: setup() sources lib.sh, which sets `pipefail`, so an
# empty src/ made `ls` fail the whole pipeline and the test FAILED on the assignment rather than
# reaching its own skip. It was invisible in the precursor, where src/ always had footage, and it
# is exactly the shape this suite exists to catch — a guard that cannot be reached.
setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
	# lib.sh sets -euo pipefail; that is fine to inherit inside a bats test body.
	source "$SCRIPTS/lib.sh"
}

# Mean luma of the first frame, 10-bit scale. `metadata=print` logs at INFO, so -v error would
# suppress the only output that matters — the same trap grade.sh's exposure probe hit.
_yavg() {  # _yavg <file>
	ffmpeg -v info -i "$1" -frames:v 1 -vf signalstats,metadata=print:file=- -f null - 2>/dev/null \
		| sed -n 's/.*lavfi\.signalstats\.YAVG=//p' | head -1
}

# The first real clip wherever the pipeline itself would look for footage, or nothing.
# resolve_work_dir, not the repo's src/: three tests looked only in the repo, so with media kept
# outside it (ADR 0006's .workdir) they skipped — one of them the only render of the production
# graph on real footage — while the tests beside them ran.
_real_clip() {
	local work
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	ls "$work"/src/*.mov 2>/dev/null | head -1 || true
}

# ASSERTION FORM MATTERS HERE. bats 1.14 does NOT fail a test on a bare `[[ ]]` that returns false
# in the middle of a test body: `[[` is a shell keyword, and the mechanism bats uses to spot a
# failure only tracks simple commands, so the false result is discarded and the test's verdict
# comes from its LAST command. `[` is a builtin and IS tracked, which is why `[ ]` assertions
# behave as expected. Verified with a two-line probe, and it had already hidden a real defect: a
# tag test stayed green while the message it asserts on was renamed.
#
# So every `[[ ]]` here ends in `|| fail ...`, which is a function call and therefore a simple
# command. Do not remove the guard to tidy a line up.
fail() {
	echo "ASSERTION FAILED: $*" >&2
	return 1
}

# --- require_nonempty --------------------------------------------------------

@test "require_nonempty accepts a file with content" {
	echo data > "$BATS_TEST_TMPDIR/f"
	run require_nonempty "$BATS_TEST_TMPDIR/f" "test"
	[ "$status" -eq 0 ]
}

@test "require_nonempty rejects a zero-byte file" {
	: > "$BATS_TEST_TMPDIR/empty"
	run require_nonempty "$BATS_TEST_TMPDIR/empty" "test"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing or empty"* ]] || fail "[[ \"$output\" == *\"missing or empty\"* ]]"
}

@test "require_nonempty rejects a missing file" {
	run require_nonempty "$BATS_TEST_TMPDIR/nope" "test"
	[ "$status" -ne 0 ]
}

# --- require_portrait --------------------------------------------------------
# The guard that stops a landscape master being silently squashed into 1080x1920.
# 11 of this shoot's 19 clips are landscape, so this is not a hypothetical.

@test "require_portrait refuses a landscape clip" {
	run require_portrait "$FIXTURES/landscape_tagged.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]] || fail "[[ \"$output\" == *\"REFUSING\"* ]]"
	# The refusal's own words. "landscape" only ever matched the fixture's FILENAME in the message,
	# so it held whatever the guard said.
	[[ "$output" == *"not portrait"* ]] || fail "not refused as non-portrait: $output"
}

@test "require_portrait reports the real dimensions, not a guess" {
	run require_portrait "$FIXTURES/landscape_tagged.mov"
	[[ "$output" == *"128x72"* ]] || fail "[[ \"$output\" == *\"128x72\"* ]]"
}

@test "require_portrait refuses a clip it cannot measure" {
	# The guard's whole job is to refuse rather than let a landscape clip be squashed silently, so
	# "I could not tell" must land on refuse. It did not: an empty dimension makes the numeric test
	# ERROR, and an `if` reads an erroring condition as false, so the clip was accepted. Same
	# fail-open shape as the trailing comma on this camera's csv output, which is what this guard
	# was written to replace in the first place.
	#
	# A tool that answers nothing is the honest way to reproduce it. It shadows ffmpeg now rather
	# than ffprobe: the measurement used to write a PNG and ffprobe it, and reads the decoded
	# frame's own size from showinfo instead — so the decode and the measurement are one step and
	# there is no longer a way to lose only the second half.
	local bin="$BATS_TEST_TMPDIR/stub-bin"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 0\n' > "$bin/ffmpeg"
	chmod +x "$bin/ffmpeg"
	PATH="$bin:$PATH" run require_portrait "$FIXTURES/portrait_tagged.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]] || fail "[[ \"$output\" == *\"REFUSING\"* ]]"
}

# --- verify_bt709 ------------------------------------------------------------
# Shipped broken: compared ffprobe's output (which prints the stream TWICE for these files,
# plus a blank line) against one expected line, so it failed on correctly tagged files.

@test "verify_bt709 PASSES on a correctly tagged file" {
	run verify_bt709 "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ]
}

@test "verify_bt709 FAILS on a bt2020-tagged file" {
	run verify_bt709 "$FIXTURES/portrait_bt2020.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TAG CHECK FAILED"* ]] || fail "[[ \"$output\" == *\"TAG CHECK FAILED\"* ]]"
}

@test "probe_tags dedups ffprobe's repeated stream on a REAL camera file" {
	# This MUST use real footage. ffprobe repeats the video stream (and adds a blank line) only
	# for files with the camera's [STREAM_GROUP] structure — a synthetic lavfi/prores fixture
	# prints a single line, so it cannot exercise the dedup at all. Verified by mutation: with
	# the dedup removed, a synthetic-fixture version of this test still passed. Real file: 3
	# lines. Synthetic: 1.
	# Footage lives under the work dir, which is NOT the repo when media is kept outside it
	# (see scripts/lib.sh resolve_work_dir). Resolve it the same way the pipeline does.
	local real
	real="$(_real_clip)"; [ -n "$real" ] || skip "no source footage"
	# Guard the guard: confirm the raw output really is multi-line, or this test proves nothing.
	local raw
	raw=$(ffprobe -v error -select_streams v:0 \
		-show_entries stream=color_space,color_transfer,color_primaries \
		-of csv=p=0 "$real" | wc -l | tr -d ' ')
	[ "$raw" -gt 1 ] || skip "this clip does not trigger the repeat; test would be vacuous"
	run probe_tags "$real"
	[ "${#lines[@]}" -eq 1 ]
}

@test "verify_bt709 gives a verdict (not a parse artefact) on a REAL camera file" {
	# Footage lives under the work dir, which is NOT the repo when media is kept outside it
	# (see scripts/lib.sh resolve_work_dir). Resolve it the same way the pipeline does.
	local real
	real="$(_real_clip)"; [ -n "$real" ] || skip "no source footage"
	# Source footage is bt2020-tagged, so this must FAIL — and fail with the tag message, not
	# because the comparison tripped over multi-line output.
	run verify_bt709 "$real"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TAG CHECK FAILED"* ]] || fail "[[ \"$output\" == *\"TAG CHECK FAILED\"* ]]"
	[[ "$output" == *"bt2020"* ]] || fail "[[ \"$output\" == *\"bt2020\"* ]]"
}

# --- safe_retag --------------------------------------------------------------
# Shipped broken on bash 3.2 (macOS): an empty array under `set -u` raised "unbound variable",
# so the retag never ran. shellcheck does not flag this — only executing it does.

@test "safe_retag works with NO extra args (the bash 3.2 empty-array case)" {
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/x.mov"
	run safe_retag "$BATS_TEST_TMPDIR/x.mov"
	[ "$status" -eq 0 ]
	[[ "$output" != *"unbound variable"* ]] || fail "[[ \"$output\" != *\"unbound variable\"* ]]"
	run probe_tags "$BATS_TEST_TMPDIR/x.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "safe_retag works WITH extra args" {
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/y.mov"
	run safe_retag "$BATS_TEST_TMPDIR/y.mov" -metadata "comment=test"
	[ "$status" -eq 0 ]
	run probe_tags "$BATS_TEST_TMPDIR/y.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "safe_retag leaves the original intact when the remux fails" {
	# A text file is not remuxable; the original must survive rather than be replaced by a
	# zero-byte failure. This is the incident that destroyed a finished 170MB render.
	echo "not a video" > "$BATS_TEST_TMPDIR/z.mov"
	before=$(cat "$BATS_TEST_TMPDIR/z.mov")
	run safe_retag "$BATS_TEST_TMPDIR/z.mov"
	[ "$status" -ne 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/z.mov")" = "$before" ]
	[ ! -f "$BATS_TEST_TMPDIR/z_tagged.mov" ]
}

# --- check_disk_space --------------------------------------------------------

@test "check_disk_space passes when space is plentiful" {
	run check_disk_space "$BATS_TEST_TMPDIR" 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"disk OK"* ]] || fail "[[ \"$output\" == *\"disk OK\"* ]]"
}

@test "check_disk_space fails when asking for an absurd amount" {
	run check_disk_space "$BATS_TEST_TMPDIR" 99999999
	[ "$status" -ne 0 ]
	[[ "$output" == *"LOW DISK SPACE"* ]] || fail "[[ \"$output\" == *\"LOW DISK SPACE\"* ]]"
}
@test "check_disk_space works on a directory that does not exist yet" {
	# The stages call this BEFORE `mkdir -p`, so on a first run into a fresh work dir the path is
	# absent. df then fails, the arithmetic expansion gets an empty operand, and the stage dies
	# with a bash syntax error instead of a disk verdict — a guard that aborts the run it was
	# meant to protect.
	run check_disk_space "$BATS_TEST_TMPDIR/dist/03-final" 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"available in $BATS_TEST_TMPDIR/dist/03-final"* ]] || fail "[[ \"$output\" == *\"available in $BATS_TEST_TMPDIR/dist/03-final\"* ]]"
	[[ "$output" != *"syntax error"* ]] || fail "[[ \"$output\" != *\"syntax error\"* ]]"
}

# bats test_tags=slow
@test "every stage checks free space on the volume it writes to" {
	# The work dir became opt-in, and three of the four call sites kept asking about the REPO's
	# volume while writing to the work dir's. With no .workdir present those are the same path, so
	# the defect is invisible locally — which is exactly why it shipped. Point the work dir
	# somewhere else and the two separate.
	local work="$BATS_TEST_TMPDIR/elsewhere" s
	mkdir -p "$work/src" "$work/dist/01-baseline" "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/01-baseline/CLIP_baseline.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	for s in 01-baseline 02-grade 03-final; do
		GRADE_WORK_DIR="$work" run "$SCRIPTS/$s.sh" CLIP
		[[ "$output" == *"available in $work/dist"* ]] \
			|| fail "$s.sh measured the wrong volume: $output"
	done
	# grade.sh is the path README tells you to run, and it had no disk guard at all while the four
	# staged scripts did. A test named "every stage" that skipped it is how that went unnoticed.
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 STAB=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *"available in $work/dist"* ]] \
		|| fail "grade.sh measured no volume at all: $output"
}


# --- safe_retag's SECOND guard ------------------------------------------------
# The exit-code check catches a crashing ffmpeg; the `-s` check behind it is for ffmpeg exiting 0
# having written nothing.
#
# HONEST NOTE ON COVERAGE: mutation testing shows removing that `-s` check changes NOTHING
# observable — `mv` then fails on the missing file and `set -e` aborts, so the original survives
# either way. No test can distinguish the two implementations, because there is no behavioural
# difference to detect. The guard is redundant defence-in-depth and the escaping mutation is
# correct, not a gap.
#
# So this test asserts the PROPERTY that matters (the original is never destroyed), not the
# specific message. It would catch a future refactor that dropped `set -e` or reordered the mv.

@test "safe_retag never destroys the original when ffmpeg produces nothing" {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/ffmpeg"
	chmod +x "$BATS_TEST_TMPDIR/bin/ffmpeg"
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/keep.mov"
	before=$(md5 -q "$BATS_TEST_TMPDIR/keep.mov")
	PATH="$BATS_TEST_TMPDIR/bin:$PATH" run safe_retag "$BATS_TEST_TMPDIR/keep.mov"
	[ "$status" -ne 0 ]
	[ "$(md5 -q "$BATS_TEST_TMPDIR/keep.mov")" = "$before" ]
}

# --- argument quoting ---------------------------------------------------------

@test "safe_retag's -map argument survives a hostile working directory" {
	# `-map 0:a:0?` contains a glob character. Unquoted, bash only survives it because unmatched
	# globs pass through literally — so a file whose name matches would silently change the
	# argument. (zsh errors on it outright, which is how this was found.)
	cd "$BATS_TEST_TMPDIR"
	touch '0:a:00'
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/q.mov"
	run safe_retag "$BATS_TEST_TMPDIR/q.mov"
	[ "$status" -eq 0 ]
	run probe_tags "$BATS_TEST_TMPDIR/q.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

# --- resolve_work_dir ----------------------------------------------------------
# This function decides WHERE every stage reads and writes. Two shipped defects traced back to it
# being untested: three stages checked free space on the repo's volume while writing to the work
# dir's, and grade.sh resolved its stabilisation cache two levels off. Neither was visible locally,
# because with no .workdir present the work dir IS the repo root and the wrong path is the right
# one by accident. Every test below therefore sets a work dir that is genuinely elsewhere.

@test "resolve_work_dir falls back to the repo root when nothing is configured" {
	local root="$BATS_TEST_TMPDIR/root"
	mkdir -p "$root"
	run env -u GRADE_WORK_DIR bash -c \
		"source '$SCRIPTS/lib.sh'; resolve_work_dir '$root'"
	[ "$status" -eq 0 ]
	[ "$output" = "$root" ]
}

@test "resolve_work_dir prefers GRADE_WORK_DIR over a .workdir file" {
	local root="$BATS_TEST_TMPDIR/root2" env_dir="$BATS_TEST_TMPDIR/from-env"
	mkdir -p "$root" "$env_dir" "$BATS_TEST_TMPDIR/from-file"
	printf '%s\n' "$BATS_TEST_TMPDIR/from-file" > "$root/.workdir"
	GRADE_WORK_DIR="$env_dir" run resolve_work_dir "$root"
	[ "$status" -eq 0 ]
	[ "$output" = "$env_dir" ]
}

@test "resolve_work_dir reads .workdir, skipping comments and trailing whitespace" {
	local root="$BATS_TEST_TMPDIR/root3" target="$BATS_TEST_TMPDIR/chosen"
	mkdir -p "$root" "$target" "$BATS_TEST_TMPDIR/ignored"
	# A comment first, then the real path with trailing blanks, then a decoy second line.
	printf '# the media lives on the external disk\n%s   \n%s\n' \
		"$target" "$BATS_TEST_TMPDIR/ignored" > "$root/.workdir"
	run env -u GRADE_WORK_DIR bash -c \
		"source '$SCRIPTS/lib.sh'; resolve_work_dir '$root'"
	[ "$status" -eq 0 ]
	[ "$output" = "$target" ]
}

@test "resolve_work_dir expands a leading ~ in .workdir" {
	local root="$BATS_TEST_TMPDIR/root4"
	mkdir -p "$root"
	# $HOME always exists, so this checks expansion without inventing a directory.
	printf '~\n' > "$root/.workdir"
	run env -u GRADE_WORK_DIR bash -c \
		"source '$SCRIPTS/lib.sh'; resolve_work_dir '$root'"
	[ "$status" -eq 0 ]
	[ "$output" = "$HOME" ]
}

@test "resolve_work_dir refuses a configured directory that does not exist" {
	local root="$BATS_TEST_TMPDIR/root5"
	mkdir -p "$root"
	GRADE_WORK_DIR="$BATS_TEST_TMPDIR/absent" run resolve_work_dir "$root"
	[ "$status" -ne 0 ]
	# The message must name both escape hatches, or the reader cannot act on it.
	[[ "$output" == *"does not exist"* ]] || fail "[[ \"$output\" == *\"does not exist\"* ]]"
	[[ "$output" == *"GRADE_WORK_DIR"* ]] || fail "[[ \"$output\" == *\"GRADE_WORK_DIR\"* ]]"
	[[ "$output" == *".workdir"* ]] || fail "[[ \"$output\" == *\".workdir\"* ]]"
}

# --- smoke: the scripts must actually RUN -------------------------------------
# These exist because the rest of this suite once passed in full while FOUR functions were missing
# from lib.sh and every stage script died on the first line with "command not found". shellcheck
# does not run the code, the parity check does not touch lib.sh, and the unit tests only call the
# handful of functions they cover — so nothing noticed the pipeline was completely broken.
#
# A suite that cannot detect "the program does not start" is not a suite.

@test "lib.sh defines every function the stage scripts call" {
	# DERIVED, NOT LISTED. This used to hardcode ten names and was not updated when the delivery
	# chain moved into lib.sh, so it silently stopped covering source_fps, stab_prefix,
	# grain_plate, delivery_image_chain, delivery_grain_branch and render_delivery — six of the
	# sixteen, including the one that protects approved deliverables. A test named for "every
	# function" that checks a fixed subset is the coverage-shaped hole CLAUDE.md rules out.
	#
	# So the names come from the scripts: every word in COMMAND POSITION in the stage scripts and
	# grade.sh — line start, after `$(`, a pipe, `&&`, `||`, `;`, or a keyword — minus the functions
	# a script defines for itself. Each must resolve to something after lib.sh is sourced (setup()
	# does that); a helper renamed on one side only resolves to nothing. Line-start words followed by
	# `|` or `)` are case patterns, and a continuation line is an argument list, so both are read for
	# `$(` calls only — except the command after a one-line case arm's `)`, which is a real call.
	local fn missing="" called own
	called=$(perl -ne '
		my $cont = $prev_cont; $prev_cont = /\\$/;
		next if /^\s*#/;
		my $w = qr/([a-z_][a-z0-9_]*)(?![a-z0-9_]|\+?=|\()/;
		while (/(?:\$\(|\s(?:\||\|\||&&|;)\s+|(?:^\s*|;\s*)(?:if|elif|then|else|do|while|until|!)\s+)$w/g) { print "$1\n" }
		print "$1\n" if !$cont && /^\s*([a-z_][a-z0-9_]*)(?![a-z0-9_]|\+?=|\(|\||\))/;
		print "$1\n" if /^\s*(?:&&|\|\|)\s+([a-z_][a-z0-9_]*)/;
		print "$1\n" if /;;\s*$/ && /\)\s+([a-z_][a-z0-9_]*)(?![a-z0-9_]|\+?=|\()/;
	' "$SCRIPTS"/0*.sh "$SCRIPTS"/grade.sh | sort -u)
	own=$(grep -hoE '^[[:space:]]*[a-z_]+\(\)' "$SCRIPTS"/0*.sh "$SCRIPTS"/grade.sh | tr -d '() \t' || true)

	# The extraction has to be seen to work, or a pattern that matches nothing passes green: every
	# lib.sh function a stage script names outside a comment must be among the calls it found.
	# Here-strings rather than pipes into `grep -q`: under pipefail the writer can die of SIGPIPE
	# when grep exits on its first match, and the lookup then reads as "not found".
	local code
	code=$(grep -vhE '^[[:space:]]*#' "$SCRIPTS"/0*.sh "$SCRIPTS"/grade.sh)
	for fn in $(grep -oE '^[a-z_]+\(\)' "$SCRIPTS/lib.sh" | tr -d '()'); do
		grep -qw "$fn" <<< "$code" || continue
		grep -qx "$fn" <<< "$called" || missing="$missing $fn"
	done
	[ -z "$missing" ] || fail "the call extraction missed lib.sh functions the scripts use:$missing"
	for fn in render_deliverable grade_chain require_portrait deliverable_crops size_is_portrait; do
		grep -qx "$fn" <<< "$called" || fail "the call extraction did not find $fn: $called"
	done

	for fn in $called; do
		grep -qx "$fn" <<< "$own" && continue
		[ -n "$(type -t "$fn")" ] || missing="$missing $fn"
	done
	[ -z "$missing" ] || fail "stage scripts call names nothing defines:$missing"
}

@test "every stage script starts and reports usage rather than dying" {
	for s in 01-baseline 02-grade 03-final 00-stabilise-detect; do
		run "$BATS_TEST_DIRNAME/../scripts/$s.sh" __NO_SUCH_CLIP__
		# It must fail on the MISSING CLIP, not on a broken script.
		[[ "$output" != *"command not found"* ]] || fail "$s.sh: $output"
		[[ "$output" != *"unbound variable"* ]]  || fail "$s.sh: $output"
		[[ "$output" == *"not found"* ]]         || fail "$s.sh gave: $output"
	done
}

@test "every stage script reports usage when given NO arguments" {
	# The test above asserts "unbound variable" never appears, which is exactly what a bare `$1`
	# under `set -u` produces — but it always passed an argument, so it could not see it. All four
	# stage scripts died with "line NN: $1: unbound variable"; only grade.sh printed a usage line.
	for s in 01-baseline 02-grade 03-final 00-stabilise-detect grade; do
		run "$BATS_TEST_DIRNAME/../scripts/$s.sh"
		[ "$status" -ne 0 ] || fail "$s.sh exited 0 with no arguments"
		[[ "$output" != *"unbound variable"* ]] || fail "$s.sh died on \$1 instead of saying usage: $output"
		[[ "$output" == *"usage:"* ]] || fail "$s.sh gave no usage line: $output"
	done
}

# bats test_tags=slow
@test "grade.sh plans a real clip end to end (dry run)" {
	local src
	src="$(_real_clip)"; [ -n "$src" ] || skip "no source footage"
	# Real footage in, but the OUTPUT goes to a temp dir. Without GRADE_WORK_DIR this ran against
	# the repo root, so every check.sh run left a dist/reports/run-*.txt and a per-clip tone cube
	# in the tree someone actually delivers from — 38 report files had accumulated.
	mkdir -p "$BATS_TEST_TMPDIR/dryrun"
	GRADE_WORK_DIR="$BATS_TEST_TMPDIR/dryrun" DRY=1 run "$BATS_TEST_DIRNAME/../scripts/grade.sh" "$src"
	[ "$status" -eq 0 ]
	[[ "$output" == *"clip(s)"* ]] || fail "[[ \"$output\" == *\"clip(s)\"* ]]"
	[[ "$output" != *"command not found"* ]] || fail "[[ \"$output\" != *\"command not found\"* ]]"
}

@test "grade.sh reads the transform cache that stage 00 writes" {
	# grade.sh reassigned WORK from the work-dir root to its own scratch dir, then built the
	# transform path from the reassigned value — landing two levels off, at
	# <work>/dist/.grade-work/dist/stab/. So it never saw a transform stage 00 had already
	# computed and silently paid ~65s per clip to redo it. One name doing two jobs.
	#
	# Transforms are motion-only and survive a re-grade, so one cache is correct. Content here is
	# irrelevant: this asserts the PATH both entry points agree on, not the warp.
	local work="$BATS_TEST_TMPDIR/gwork"
	mkdir -p "$work/src" "$work/dist/stab"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	printf 'stand-in for a real transform\n' > "$work/dist/stab/CLIP.trf"
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$work/dist/stab/CLIP.trf"* ]] \
		|| fail "grade.sh did not find the shared transform: $output"
}

@test "a transform older than its source is not reused" {
	# Transforms are measured against the DECODED frame, so re-orienting a source invalidates its
	# transform: the file then describes motion in a frame that no longer exists. Once the cache is
	# shared (above), a stale entry is silently reused by both entry points — the warp fights
	# footage it was never measured on. Same freshness rule ensure_tone_lut already applies to
	# shipped.cube against look.json.
	local work="$BATS_TEST_TMPDIR/stale"
	_stale_transform "$work"
	GRADE_WORK_DIR="$work" DRY=1 MATCH=0 run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"stale"* ]] \
		|| fail "grade.sh reused a stale transform: $output"
	[[ "$output" != *"stabilising from"* ]] || fail "[[ \"$output\" != *\"stabilising from\"* ]]"
}

@test "grade.sh takes its tone values from look.json, not from itself" {
	# "Look values live in look.json, never hardcoded in a script" is a settled rule, and the
	# production path was breaking it: it read colour, grain and stabilisation from look.json but
	# carried its own copy of the whole tone block. So a grade sent from the Bench (since removed) updated
	# shipped.cube and the staged path while grade.sh kept rendering the previous tone — the
	# two-copies-one-edited failure that look() exists to end, one layer up.
	local work="$BATS_TEST_TMPDIR/lookwork" look="$BATS_TEST_TMPDIR/other-look.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# A gamma nothing in the repo contains, so a pass can only come from reading this file.
	#
	# DERIVED from the real look.json rather than written out here. look() has no fallbacks, so the
	# key set is a contract — and a hand-written copy of it goes stale the moment a key is added,
	# which is how adding the correction block turned this test red for a reason that had nothing
	# to do with what it asserts.
	python3 - "$BATS_TEST_DIRNAME/../look.json" "$look" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["tone"]["gamma"] = 1.44
json.dump(d, open(sys.argv[2], "w"))
PY
	LOOK_FILE="$look" GRADE_WORK_DIR="$work" DRY=1 MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"gamma=1.44"* ]] \
		|| fail "grade.sh ignored look.json's tone block: $output"
}

# --- solve-gamma.py ------------------------------------------------------------
# The exposure solve was a python3 -c program assembled by string interpolation inside grade.sh,
# so nothing could reach it. A degenerate probe raised inside it — math.log(0) on a near-black
# frame, a zero denominator at y == 1.0 — and under `set -euo pipefail` that killed the whole
# batch at clip n rather than rendering that clip with the frozen curve.

@test "solve-gamma returns the reference gamma when the clip matches the reference" {
	run "$SCRIPTS/solve-gamma.py" 609 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "2.020" ]
}

@test "solve-gamma moves the curve for a clip darker than the reference" {
	run "$SCRIPTS/solve-gamma.py" 400 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" != "2.020" ]
}

@test "solve-gamma falls back rather than dividing by zero on a blown frame" {
	# y == 1.0 makes log(y) zero. This used to abort the batch.
	run "$SCRIPTS/solve-gamma.py" 1023 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "2.020" ]
}

@test "solve-gamma falls back rather than taking log(0) on a black frame" {
	run "$SCRIPTS/solve-gamma.py" 0 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "2.020" ]
}

@test "solve-gamma clamps instead of extrapolating a curve nobody has looked at" {
	# Four stops under the tuning exposure has no meaningful solve, only a nearest sane curve.
	run "$SCRIPTS/solve-gamma.py" 12 609 2.02
	[ "$status" -eq 0 ]
	[ "$output" = "1.200" ]
}

@test "solve-gamma rejects a non-numeric probe instead of interpolating it into a program" {
	run "$SCRIPTS/solve-gamma.py" "1); import os; os.exit(0" 609 2.02
	[ "$status" -ne 0 ]
	[[ "$output" == *"non-numeric"* ]] || fail "[[ \"$output\" == *\"non-numeric\"* ]]"
}

@test "safe_retag leaves a correctly tagged file untouched" {
	# Encoders don't reliably STAMP the tags, which is why safe_retag exists — but they don't
	# reliably get them wrong either, and the function remuxed unconditionally. On the staged path
	# that is a full read+write of two ~2.3GB ProRes masters per clip, roughly 9GB of I/O, to
	# change nothing. lib.sh's own header has always described verify-then-fix.
	#
	# Inode, not mtime: a remux writes a temp file and moves it over the original, so the inode
	# changes even when the bytes would not.
	local f="$BATS_TEST_TMPDIR/already-ok.mov" before after
	cp "$FIXTURES/portrait_tagged.mov" "$f"
	before=$(stat -f%i "$f")
	run safe_retag "$f"
	[ "$status" -eq 0 ]
	after=$(stat -f%i "$f")
	[ "$before" = "$after" ] || fail "rewrote a file that was already correct"
	# ...and it must still report the verdict, not fall silent.
	[[ "$output" == *"tags OK"* ]] || fail "[[ \"$output\" == *\"tags OK\"* ]]"
}

@test "re-rendering a master does not invalidate its transform" {
	# The cache is shared, but the two entry points judged freshness against two different
	# references: grade.sh against the source, the final stages against the graded master. So a
	# transform written by grade.sh went stale the moment a master re-rendered, and the delivery
	# silently went out unstabilised.
	#
	# The source footage is the only correct reference. Transforms are motion-only and survive a
	# re-grade — change the look, tone or saturation and the same warp still applies — so the
	# graded master's mtime says nothing about whether the camera moved.
	local work="$BATS_TEST_TMPDIR/prov"
	mkdir -p "$work/src" "$work/dist/02-graded" "$work/dist/stab"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	printf 'transform measured on this source\n' > "$work/dist/stab/CLIP.trf"
	# The master is re-rendered AFTER the transform. That is a re-grade, not a re-shoot.
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	# Stamp the order explicitly. bash 3.2's -nt compares whole seconds, and all three files are
	# created inside one second here, so without this the transform is not "newer" than anything.
	touch -t 202609010000 "$work/src/CLIP.mov"
	touch -t 202609020000 "$work/dist/stab/CLIP.trf"
	touch -t 202609030000 "$work/dist/02-graded/CLIP_graded.mov"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP reels
	[[ "$output" == *"stabilising with"* ]] \
		|| fail "called a valid transform stale after a re-grade: $output"
}

@test "transform_is_fresh refuses when the source it was measured from is gone" {
	# Cannot prove freshness, so do not warp. A stale transform fights footage it was never
	# measured on, which is visibly wrong output; dropping stabilisation is merely less good.
	local trf="$BATS_TEST_TMPDIR/orphan.trf"
	printf 'x\n' > "$trf"
	run transform_is_fresh "$trf" "$BATS_TEST_TMPDIR/no-such-source.mov"
	[ "$status" -ne 0 ]
}

@test "every stage creates its own output directory" {
	# The staged scripts once relied on a dist/*/.gitkeep existing in the REPO, so with a work dir
	# set they wrote into a directory that does not exist — and ffmpeg reported it only at the end
	# of a full-length encode. The markers have since been deleted, which makes this test the only
	# thing standing between a fresh clone and that bug returning. The test above pre-creates every
	# output folder and so cannot see it; this one deliberately does not.
	local work="$BATS_TEST_TMPDIR/bare" s
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	mkdir -p "$work/dist/01-baseline" "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/01-baseline/CLIP_baseline.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	# dist/03-final is the one nothing has created.
	[ ! -d "$work/dist/03-final" ]
	for s in reels feed; do
		GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP "$s"
		# Assert the directory itself, not the absence of an error message: this fixture is too
		# small to survive the full delivery chain, and an unrelated encode failure must not let
		# this pass vacuously.
		[ -d "$work/dist/03-final" ] \
			|| fail "03-final.sh $s did not create its output dir: $output"
		rm -rf "$work/dist/03-final"
	done
}

# --- render_delivery -----------------------------------------------------------

@test "a failed re-render leaves the approved deliverable byte-identical" {
	# `ffmpeg -y` pointed at the delivery path truncates the existing file before it knows whether
	# the graph even initialises. Measured on this repo: an approved mp4 re-rendered with a broken
	# graph was left at 0 bytes, ffmpeg exiting 234. require_nonempty reported the failure loudly
	# and the deliverable was already gone — and per docs/adr/0004, getting it back means
	# regenerating the baseline and the master first.
	local out="$BATS_TEST_TMPDIR/approved.mp4" before
	ffmpeg -y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out" -v error
	before=$(md5 -q "$out")

	# A filter graph that fails at initialisation, which is the dangerous shape: ffmpeg has already
	# opened the output by then.
	run render_delivery "$out" "deliberately broken encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
		-filter_complex "[0:v]nosuchfilter=1[o]" -map "[o]" -frames:v 1
	[ "$status" -ne 0 ]
	[ -s "$out" ] || fail "the approved deliverable was destroyed"
	[ "$(md5 -q "$out")" = "$before" ] || fail "the approved deliverable was modified"
	[ ! -f "$BATS_TEST_TMPDIR/approved.partial.mp4" ] || fail "left a staging file behind"
}

@test "render_delivery installs a good render and tags it" {
	local out="$BATS_TEST_TMPDIR/fresh.mp4"
	run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	run probe_tags "$out"
	[ "$output" = "bt709,bt709,bt709" ]
}

# --- ensure_tone_lut -----------------------------------------------------------
# This had no test at all, and its freshness check was mtime-only. git does not preserve mtimes, so
# on every fresh clone the committed cube lands NEWER than look.json and was trusted forever: with
# look.json backdated and a parameter changed, the stale curve stayed in place in silence. The
# guarantee held only on the machine where the edit happened.

_tone_root() {  # build a throwaway repo root with its own look.json and generator
	local root="$1" gamma="$2"
	mkdir -p "$root/luts/tone" "$root/scripts"
	cp "$BATS_TEST_DIRNAME/../scripts/make-tone-lut.py" "$BATS_TEST_DIRNAME/../scripts/cubefile.py" "$root/scripts/"
	cat > "$root/look.json" <<JSON
{ "tone": { "gamma": $gamma, "pivot": 0.39, "contrast": 1.09,
            "toe": 0.0, "shoulder": 0.1, "black": 0.025 } }
JSON
}

@test "ensure_tone_lut regenerates a cube that disagrees with look.json" {
	local root="$BATS_TEST_TMPDIR/tone-stale"
	_tone_root "$root" 2.02
	# A cube built at a DIFFERENT gamma, then stamped newer than look.json — exactly the state a
	# fresh clone produces, and the state the old mtime check called fresh.
	"$root/scripts/make-tone-lut.py" "$root/luts/tone/shipped.cube" \
		--gamma 1.5 --pivot 0.39 --contrast 1.09 --toe 0.0 --shoulder 0.1 --black 0.025 >/dev/null
	touch -t 202609010000 "$root/look.json"
	touch -t 202609020000 "$root/luts/tone/shipped.cube"

	LOOK_FILE="$root/look.json" run ensure_tone_lut "$root"
	[ "$status" -eq 0 ]
	run head -1 "$root/luts/tone/shipped.cube"
	[[ "$output" == *"gamma=2.02"* ]] \
		|| fail "kept a cube built at the wrong gamma: $output"
}

@test "ensure_tone_lut does not rewrite a cube that already matches" {
	local root="$BATS_TEST_TMPDIR/tone-current" before after
	_tone_root "$root" 2.02
	LOOK_FILE="$root/look.json" ensure_tone_lut "$root"
	before=$(stat -f%i "$root/luts/tone/shipped.cube")
	LOOK_FILE="$root/look.json" run ensure_tone_lut "$root"
	[ "$status" -eq 0 ]
	after=$(stat -f%i "$root/luts/tone/shipped.cube")
	[ "$before" = "$after" ] || fail "regenerated an already-current cube"
}

@test "the tone cube records the gamma it was built at" {
	# The old TITLE recorded every parameter except gamma — the one that was actually re-tuned
	# (2.09 -> 2.02), so a committed cube could not be traced back to the curve it encodes.
	run head -1 "$BATS_TEST_DIRNAME/../luts/tone/shipped.cube"
	[[ "$output" == *"gamma="* ]] || fail "[[ \"$output\" == *\"gamma=\"* ]]"
}

# bats test_tags=slow
@test "the production filter graph renders a real clip end to end" {
	# NOTHING else in this suite executes this graph. shellcheck cannot see inside a filter string
	# — it reported clean on both of the previously shipped load-bearing bugs — the parity check
	# touches only the tone curve, and every other grade.sh test stops at DRY=1. So dropping a
	# label here went green and failed three minutes into a 19-clip run, after the render had
	# already truncated the deliverable it was overwriting.
	#
	# Real footage only: a synthetic clip does not have this camera's stream structure, and
	# CLAUDE.md is explicit that tests covering those behaviours must skip rather than fake it.
	local src work out w h
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	work="$BATS_TEST_TMPDIR/render"
	mkdir -p "$work"

	# 0.1 seconds through the whole chain: CST, look LUT, luma-only tone via mergeplanes,
	# saturation, warmth, chroma denoise, the dithered 10->8 reduction, sharpener, grain blend.
	# MATCH stays on so the exposure probe runs too — it once returned empty on every clip
	# because `metadata=print` logs at INFO level, which `-v error` suppresses.
	PROOF=0.1 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" =~ YAVG=[0-9] ]] || fail "the exposure probe returned nothing: $output"

	out=$(ls "$work"/dist/proofs/*.mp4 2>/dev/null | head -1) || true
	[ -n "$out" ] || fail "no proof was written: $output"
	w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$out" | head -1)
	h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$out" | head -1)
	[ "$w" = "1080" ] && [ "$h" = "1920" ] || fail "delivered ${w}x${h}, wanted 1080x1920"
	# A wrongly tagged file is double-transformed by any player that trusts the tag. That is what
	# "bleached out" was, and the encoder ignoring the flags is why safe_retag exists.
	run probe_tags "$out"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "verify_bt709 PASSES on a real camera-structured file once its tags are correct" {
	# THE MISSING CASE. The other real-footage test asserts verify_bt709 returns a VERDICT, and it
	# stays green even with probe_tags' dedup removed: the source is bt2020-tagged, so the call
	# fails either way and the multi-line output still satisfies every assertion. The case that
	# catches the original bug is verify_bt709 PASSING on a file whose ffprobe prints the video
	# stream twice — which is the exact state it shipped in, unable to pass on anything.
	#
	# Found a live defect: on a camera-structured file the csv answer carries a TRAILING COMMA
	# ("bt709,bt709,bt709,"), so the comparison could never match no matter how the file was
	# tagged. CLAUDE.md documents that comma for dimensions; probe_tags had the same shape.
	local src excerpt
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	excerpt="$BATS_TEST_TMPDIR/camera-structure.mov"
	# -c copy preserves the [STREAM_GROUP] structure, the repeated stream and the trailing comma.
	# A re-encode does not, which is why the synthetic fixtures cannot cover this.
	ffmpeg -v error -y -t 0.1 -i "$src" -c copy "$excerpt"

	safe_retag "$excerpt" >/dev/null
	run verify_bt709 "$excerpt"
	[ "$status" -eq 0 ] || fail "correctly tagged real file rejected: $output"
	[[ "$output" == *"tags OK"* ]] || fail "[[ \"$output\" == *\"tags OK\"* ]]"
}

@test "probe_tags returns three clean fields on a real camera file" {
	local src
	src=$(_real_clip)
	[ -n "$src" ] || skip "no source footage"
	run probe_tags "$src"
	# Exactly three comma-separated values, no trailing comma, no blank-line artefact.
	[[ "$output" =~ ^[a-z0-9]+,[a-z0-9]+,[a-z0-9]+$ ]] \
		|| fail "probe_tags gave [$output]"
}

@test "check_disk_space reports a legible failure when df cannot answer" {
	# This branch was unreachable from the suite: the ancestor walk always hands df an existing
	# directory, so deleting the numeric validation left all five disk tests green. Without it an
	# empty answer reaches $(( )) and the stage dies with a bash arithmetic syntax error rather
	# than a message naming the path.
	local bin="$BATS_TEST_TMPDIR/nodf"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 1\n' > "$bin/df"
	chmod +x "$bin/df"
	PATH="$bin:$PATH" run check_disk_space "$BATS_TEST_TMPDIR" 1
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not measure free space"* ]] || fail "[[ \"$output\" == *\"could not measure free space\"* ]]"
	[[ "$output" != *"syntax error"* ]] || fail "[[ \"$output\" != *\"syntax error\"* ]]"
}

# --- look.json ----------------------------------------------------------------

@test "look.json answers every key the scripts ask for" {
	# look() has no fallbacks on purpose: a missing value must stop the run rather than quietly
	# substitute a different look. That makes the set of keys a contract, and nothing checked the
	# two sides of it against each other — so adding match.reference_yavg silently widened the gap
	# that already stopped the Bench's output from working.
	local key missing=""
	for key in $(grep -ho 'look \.[a-z_.]*' "$BATS_TEST_DIRNAME"/../scripts/*.sh \
	             | awk '{print $2}' | sort -u); do
		jq -e "$key" "$BATS_TEST_DIRNAME/../look.json" >/dev/null 2>&1 || missing="$missing $key"
	done
	[ -z "$missing" ] || fail "look.json is missing:$missing"
}

@test "look refuses a missing key rather than substituting a different look" {
	local look="$BATS_TEST_TMPDIR/partial.json"
	printf '{ "tone": { "gamma": 2.02 } }\n' > "$look"
	LOOK_FILE="$look" run look .grain.strength
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing .grain.strength"* ]] || fail "unhelpful message: $output"
}

@test "no script renders straight to a delivery path" {
	# The behavioural test above proves render_delivery protects the file it replaces. This pins
	# the invariant that every render actually goes through it: `ffmpeg -y` aimed at an output
	# variable truncates the existing file before the graph is known to initialise, and that is
	# how a failed re-render destroys an approved deliverable. I reintroduced exactly this while
	# rewriting stage 3, one commit after fixing it elsewhere.
	local offenders
	# Comment lines are excluded, or the note explaining the rule trips the rule.
	offenders=$(grep -n 'ffmpeg .*-y.*"\$\(OUT\|out\)"' "$BATS_TEST_DIRNAME"/../scripts/*.sh \
		| grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "renders straight to the delivery path:$offenders"
}

# --- output integrity: the deliverable that already exists ---------------------
# `ffmpeg -y` pointed at a delivery path truncates it before the graph is known to initialise, so a
# failed re-render destroys an approved file. render_delivery stages, checks and tags before
# installing. These pin BOTH halves of that: the staging behaviour, and the tag check that decides
# whether a staged file is allowed to land.

@test "a failed re-render through 03-final.sh leaves the approved deliverable byte-identical" {
	# grade.sh was converted to render_delivery and 03-final.sh was not, so the staged path still
	# truncated the file the one-pass path protected — same directory, same filename. Measured: an
	# approved 2176-byte mp4 left at 0 bytes.
	#
	# No special trigger needed. The synthetic fixture cannot survive the delivery chain (zscale
	# reports "code 3074: no path between colorspaces" on it, while a real graded master passes the
	# identical graph), so a plain run is a reliable failing render.
	local work="$BATS_TEST_TMPDIR/keepdeliv" out before
	mkdir -p "$work/src" "$work/dist/02-graded" "$work/dist/03-final"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"

	out="$work/dist/03-final/CLIP_reels-stories_9x16.mp4"
	ffmpeg -y -f lavfi -i "color=c=red:s=72x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out" -v error
	before=$(md5 -q "$out")

	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP reels
	[ "$status" -ne 0 ] || skip "the fixture rendered successfully; this test needs a failing render"
	[ -s "$out" ] || fail "the approved deliverable was truncated"
	[ "$(md5 -q "$out")" = "$before" ] || fail "the approved deliverable was modified"
	[ ! -f "$work/dist/03-final/CLIP_reels-stories_9x16.partial.mp4" ] \
		|| fail "left a staging file in the folder someone uploads from"
}

@test "render_delivery refuses to install a file it could not tag" {
	# The ffmpeg result and the emptiness check were both guarded with `if !`; the retag was a bare
	# call. That fails open wherever `set -e` is suppressed — including this `run` — and installed a
	# file measuring unknown,unknown,unknown, returning 0. A wrongly tagged file is the
	# double-transform lib.sh exists to prevent.
	local out="$BATS_TEST_TMPDIR/untaggable.mp4"
	safe_retag() { return 1; }     # the remux fails, however it fails
	run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -ne 0 ] || fail "installed a file it could not tag, and reported success"
	[ ! -e "$out" ] || fail "installed an untagged file at $out"
	[ ! -e "$BATS_TEST_TMPDIR/untaggable.partial.mp4" ] || fail "left a staging file behind"
}

# bats test_tags=slow
@test "a clip whose render fails does not take the rest of the batch with it" {
	# Measured: a two-clip run whose first render failed never attempted the second, printed no
	# summary line, and left the report ending mid-file. grade.sh already skips a non-portrait clip
	# and continues; a render failure went straight through `set -e` instead. In a 19-clip
	# unattended run a failure at clip 3 silently costs the other 16.
	#
	# The trigger is the documented one: a TRUNCATED .trf stamped newer than its source, so it
	# passes the freshness check, is not re-detected, and then dies deep in the filter graph with
	# "Cannot parse localmotion: unexpected end of file". Only AAA gets one, so BBB is the clip
	# that must still render.
	local work="$BATS_TEST_TMPDIR/batch"
	mkdir -p "$work/src" "$work/dist/stab"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/AAA.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/BBB.mov"
	printf 'VID.STAB 1\n\n' > "$work/dist/stab/AAA.trf"
	# bash 3.2's -nt compares whole seconds and these are created inside one, so stamp the order.
	touch -t 202609010000 "$work/src/AAA.mov" "$work/src/BBB.mov"
	touch -t 202609020000 "$work/dist/stab/AAA.trf"

	GRADE_WORK_DIR="$work" MATCH=0 run "$SCRIPTS/grade.sh" "$work/src"
	[[ "$output" == *"FAIL  AAA"* ]] || fail "the failing clip was not reported as failed: $output"
	[ -s "$work/dist/03-final/BBB_reels-stories_9x16.mp4" ] \
		|| fail "the batch stopped at the failing clip; BBB was never rendered: $output"
	[[ "$output" == *"1 failed"* ]] || fail "the summary did not count the failure: $output"
	[ "$status" -ne 0 ] || fail "a run with a failed clip exited 0"
}

@test "a usage error creates nothing in the output tree" {
	# grade.sh made its output directories and an empty run-*.txt BEFORE checking that it had any
	# clips, so `./grade.sh` with no arguments left litter in the folder someone delivers from —
	# and one stray report per suite run, since the no-argument test above calls exactly that.
	local work="$BATS_TEST_TMPDIR/usage"
	mkdir -p "$work"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh"
	[ "$status" -ne 0 ] || fail "no-argument run exited 0"
	[ ! -d "$work/dist" ] || fail "a usage error created $(find "$work/dist" -type f | tr '\n' ' ')"
}

# --- the grade chain: one builder, two render paths ---------------------------
# The look LUT, the luma-only tone curve and the colour ops were assembled separately by grade.sh
# and 02-grade.sh. They had already drifted once before that (grade.sh carried its own copy of the
# tone block, so a grade from the Bench moved the one-pass path and left the staged one behind),
# and the suite renders only the one-pass graph — so the staged one could break and stay green.

@test "the grade chain is built in exactly one place" {
	# Structural, because the behavioural test below cannot see a THIRD caller appearing. The
	# tell is mergeplanes: it is the one filter that only the grade head uses, so any stage script
	# naming it has started building its own copy again.
	local offenders
	# Comments are excluded, or the pointers explaining the rule trip the rule.
	offenders=$(grep -n 'mergeplanes' "$SCRIPTS"/*.sh \
		| grep -v '/lib\.sh:' | grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "builds its own grade chain instead of calling grade_chain:$offenders"
}

# bats test_tags=serial
@test "the staged grade graph initialises and renders" {
	# 02-grade.sh's graph was executed by NOTHING. shellcheck cannot see inside a filter string,
	# the parity check touches only the tone curve, and the one real render in this suite goes
	# through grade.sh. So the staged path's half of the shared builder had no cover at all, and
	# it IS a different graph: no CST prefix, no setparams.
	#
	# WHAT THIS DOES AND DOES NOT CATCH. Mutation-tested: breaking the mergeplanes mask fails it.
	# Dropping either `format=yuv444p10le` does NOT — not here and not in the real-footage render
	# either. The "Invalid argument" that pair was added for is not reproducible on ffmpeg 9.0.1,
	# which negotiates both branches to a matching format on its own. Do not read that as licence
	# to delete them: the failure is documented from a real incident, negotiation is exactly the
	# kind of thing that changes between builds, and nothing would tell you it had come back.
	#
	# A SYNTHETIC baseline is legitimate here, unlike the ffprobe tests: what is under test is
	# whether a filter graph initialises and produces pixels, which does not depend on this
	# camera's stream structure. A baseline is by definition already Rec.709 ProRes.
	local work="$BATS_TEST_TMPDIR/staged" base out
	base="$work/dist/01-baseline/CCC_baseline.mov"
	mkdir -p "$(dirname "$base")"
	ffmpeg -y -f lavfi -i "testsrc2=s=240x426:d=0.2:r=24" \
		-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$base.raw.mov" -v error
	# Tagged in a separate remux, for the reason setup_file gives: prores_ks ignores the flags.
	ffmpeg -y -i "$base.raw.mov" -map 0:v:0 -c copy \
		-color_primaries bt709 -color_trc bt709 -colorspace bt709 "$base" -v error

	GRADE_WORK_DIR="$work" run "$SCRIPTS/02-grade.sh" CCC
	[ "$status" -eq 0 ] || fail "$output"
	out="$work/dist/02-graded/CCC_graded.mov"
	[ -s "$out" ] || fail "the staged graph produced nothing: $output"
	# THE TONE CURVE MUST BE LOAD-BEARING, and proving that took three attempts — each earlier
	# one passed against a mutation it was written to catch:
	#   1. `pix_fmt is 10-bit` is vacuous. `-pix_fmt yuv422p10le` on the command line decides the
	#      answer whatever the graph did, so it passed against a chain mutated to emit 8-bit.
	#   2. `luma moved from the baseline` is nearly vacuous. colorbalance shifts luma too, so a
	#      mergeplanes mask taking the UNTONED branch still moved it — baseline 493.92, bypassed
	#      647.998, real chain 552.71 — and passed.
	#      (Bypassing it means 0x101112, not 0x011112: each byte of the mask is INPUT then PLANE,
	#      so 01 asks for input 0's chroma as luma, which is a different corruption that moves
	#      luma too. A mutation that is not the one you meant proves nothing.)
	# Rendering the same baseline through the same builder with an IDENTITY tone LUT and requiring
	# the two to differ pins the curve itself, and stays true whatever look.json currently says.
	local ident="$BATS_TEST_TMPDIR/identity.cube" flat="$work/flat.mov"
	"$SCRIPTS/make-tone-lut.py" "$ident" --gamma 1 --pivot 0.5 --contrast 1 \
		--toe 0 --shoulder 0 --black 0 >/dev/null
	ffmpeg -y -i "$base" \
		-filter_complex "[0:v]$(grade_chain "$ident" "$(look .colour.saturation)" "$(look .colour.warmth)")[o]" \
		-map "[o]" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$flat" -v error
	local y_graded y_flat
	y_graded=$(_yavg "$out")
	y_flat=$(_yavg "$flat")
	[ -n "$y_graded" ] && [ -n "$y_flat" ] || fail "could not measure luma: '$y_graded' '$y_flat'"
	[ "$y_graded" != "$y_flat" ] \
		|| fail "the tone LUT changed nothing ($y_graded either way): the curve is not reaching the output"
}

@test "every file path named in prose or in a script actually exists" {
	# Removing rotation left a runbook step telling you to pass an argument that had been silently
	# dropped, and CLAUDE.md's own rule is that deleting a concept means grepping for its name in
	# prose too. A pointer to a moved or deleted file is the same failure one level up, and it is
	# the failure mode a docs layout built on pointers invites — so it gets a guard rather than a
	# convention.
	local root="$BATS_TEST_DIRNAME/.." missing="" ref f
	# Paths that look like repo paths: a directory prefix this repo actually has, then a filename.
	#
	# THE EXTENSION LIST IS ORDERED, and jsonl comes before json on purpose: alternation is
	# first-match, so `json` alone matched `events.jsonl` as `events.json` and then reported a file
	# that does exist as missing. A guard that invents a broken pointer is worse than one that
	# misses a real one, because the next person deletes the guard.
	#
	# -I and the exclusion are load-bearing. A .pyc under tests/__pycache__ embeds the source path
	# it was compiled from, so importing a test helper once was enough to make this guard report
	# generated bytecode as a broken pointer. It greps PROSE and SCRIPTS; binaries and build caches
	# are not its business, and __pycache__ is gitignored, which is the repo already saying so.
	for ref in $(grep -rhoIE --exclude-dir=__pycache__ \
			'(docs|scripts|tests|luts|bench)/[A-Za-z0-9_/.-]+\.(md|sh|py|jsonl|json|cube|html|txt)' \
			"$root"/*.md "$root"/docs "$root"/scripts "$root"/tests 2>/dev/null | sort -u); do
		f="${ref%%[.,)]}"
		# luts/apple/ is deliberately absent on a fresh clone (Apple's licence), and the filmic
		# cubes are generated and gitignored. Both document their own absence in a SOURCE.txt.
		case "$f" in luts/apple/*|luts/filmic/*) continue ;; esac
		[ -e "$root/$f" ] || missing="$missing $f"
	done
	[ -z "$missing" ] || fail "referenced but not present:$missing"
}

# --- what reaches the filter graph --------------------------------------------
# An ffmpeg filter description is a LANGUAGE: `,` and `;` separate filters and chains, `'` quotes a
# value, `[` `]` delimit labels. Every look value is spliced into one by string interpolation, so a
# value carrying any of those ADDS FILTERS rather than being read as a number — and ffmpeg filters
# can write files (`metadata=print:file=`) and read them (`movie=`). There is no eval anywhere here,
# so this is not shell injection; the ceiling is ffmpeg doing file I/O as whoever ran the script.
#
# It matters because neither input is hand-typed. The look file arrives as the app's LOOK_FILE,
# and came before that from the Bench's shared, multi-writer artifact db; a clip FILENAME arrives
# from the camera or from whoever handed over the card. Nothing on the read side checked either one.
#
# Ported from a branch of the precursor that never landed, because it predates the chain dedupe and
# would have reinstated an inlined copy of the graph. See PROVENANCE.md.

@test "require_number accepts a number and rejects a filter fragment" {
	run require_number SAT 1.27
	[ "$status" -eq 0 ]
	[ "$output" = "1.27" ]

	run require_number BLACK "-0.08"
	[ "$status" -eq 0 ]

	run require_number SAT "1.27,metadata=print:file=/tmp/x"
	[ "$status" -ne 0 ]
	[[ "$output" == *"must be numeric"* ]] || fail "unhelpful message: $output"

	run require_number SAT ""
	[ "$status" -ne 0 ]
	[[ "$output" == *"SAT must be numeric: got ''"* ]] || fail "empty refused, but not by the guard: $output"
}

@test "require_clip_name refuses a path and refuses filter syntax" {
	run require_clip_name IMG_0609
	[ "$status" -eq 0 ]
	[ "$output" = "IMG_0609" ]

	run require_clip_name "../../escaped"
	[ "$status" -ne 0 ]
	[[ "$output" == *"contains '/'"* ]] || fail "not refused as a path: $output"

	run require_clip_name "IMG_0609'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"ffmpeg reads as filter syntax"* ]] || fail "not refused as filter syntax: $output"

	run require_clip_name ""
	[ "$status" -ne 0 ]
	[[ "$output" == *"empty clip name"* ]] || fail "not refused as empty: $output"
}

@test "grade.sh refuses a SMOOTHING that would splice a filter into the graph" {
	local work="$BATS_TEST_TMPDIR/inj-smooth" marker="$BATS_TEST_TMPDIR/smooth-written"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	SMOOTHING="30,metadata=print:file=$marker" GRADE_WORK_DIR="$work" MATCH=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ]
	# Assert the GUARD's verdict, not just a non-zero exit: a synthetic fixture fails this graph
	# for its own reasons, so `status != 0` stayed true with the guard removed and the test read as
	# coverage while covering nothing. Found by mutation.
	[[ "$output" == *"SMOOTHING must be numeric"* ]] || fail "not refused by the guard: $output"
	[ ! -f "$marker" ] || fail "the spliced filter ran and wrote $marker"
}

@test "grade.sh refuses a PROOF that would append ffmpeg arguments" {
	# PROOF is spliced UNQUOTED on purpose (-t $PROOF), so whitespace in it becomes extra ffmpeg
	# options rather than a duration. `-f mp4 <path>` then appends a second output file, which
	# walks straight past render_delivery's staging.
	local work="$BATS_TEST_TMPDIR/inj-proof" injected="$BATS_TEST_TMPDIR/injected.mp4"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	PROOF="1 -f mp4 $injected" GRADE_WORK_DIR="$work" MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"PROOF"* ]] || fail "did not name the offending variable: $output"
	[ ! -f "$injected" ] || fail "ffmpeg wrote the injected output $injected"
}

@test "03-final.sh refuses a non-numeric crop offset" {
	local work="$BATS_TEST_TMPDIR/inj-crop" marker="$BATS_TEST_TMPDIR/crop-written"
	mkdir -p "$work/src" "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP feed "750,metadata=print:file=$marker"
	[ "$status" -ne 0 ]
	# The words, not just the status: this fixture cannot complete the delivery chain, so a non-zero
	# exit and an absent marker are both true whether or not the offset was refused.
	[[ "$output" == *"CROP_Y must be numeric"* ]] || fail "not refused at the offset: $output"
	[ ! -f "$marker" ] || fail "the spliced filter ran and wrote $marker"
}

@test "03-final.sh refuses an unknown deliverable with its code, before anything is created" {
	# The spec went through a here-string, which swallows the refusal: the script carried on with
	# empty aspect terms and died on an arithmetic syntax error, with no code for a wrapper to read.
	local work="$BATS_TEST_TMPDIR/bad-deliv"
	mkdir -p "$work/src" "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP nope
	[ "$status" -ne 0 ] || fail "accepted an unknown deliverable"
	[[ "$output" == *"REFUSING: unknown deliverable 'nope'"* ]] || fail "not refused by the spec: $output"
	[[ "$output" == *"GRADE_CODE=REFUSE_DELIVERABLE"* ]] || fail "unnamed refusal: $output"
	[[ "$output" != *"syntax error"* ]] || fail "died in arithmetic instead of refusing: $output"
	[[ "$output" != *"deliverable:"* ]] || fail "went on to plan a deliverable: $output"
	[ ! -d "$work/dist/03-final" ] || fail "created the output folder for a refused deliverable"
}

@test "every stage refuses a clip argument that escapes the work dir" {
	# The clip name is used raw as a path component. `mkdir -p "$(dirname "$OUT")"` — added when the
	# stages stopped relying on checked-in dist/*/.gitkeep markers, which are now deleted — is what
	# turns a traversal argument into a successful write: before it, the absent directory stopped
	# the render by accident.
	local work="$BATS_TEST_TMPDIR/escape" s
	mkdir -p "$work/src" "$work/dist/01-baseline" "$work/dist/02-graded"
	for s in 00-stabilise-detect 01-baseline 02-grade 03-final; do
		GRADE_WORK_DIR="$work" run "$SCRIPTS/$s.sh" "../../escaped"
		[ "$status" -ne 0 ] || fail "$s.sh accepted a traversing clip name"
		[[ "$output" == *"clip name"* ]] || fail "$s.sh gave no reason: $output"
	done
	[ ! -d "$BATS_TEST_TMPDIR/escaped" ] || fail "a stage created a directory outside the work dir"
}

@test "grade.sh refuses a clip whose FILENAME would break the filter graph" {
	# The clip name reaches lut1d=file='...' and vidstabtransform=input='...' via the tone-LUT and
	# transform paths, so a quote in it closes ffmpeg's quoting from the inside.
	local work="$BATS_TEST_TMPDIR/quotename"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/IMG_0609'.mov"
	GRADE_WORK_DIR="$work" MATCH=0 STAB=0 run "$SCRIPTS/grade.sh" "$work/src/IMG_0609'.mov"
	[ "$status" -ne 0 ] || fail "accepted a clip name containing a quote"
	[[ "$output" == *"clip name"* ]] || fail "gave no reason: $output"
}

@test "a look.json value that is not a number is refused, not rendered" {
	local work="$BATS_TEST_TMPDIR/badlook" look="$BATS_TEST_TMPDIR/hostile-look.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# Derived, so this fails on the hostile VALUE rather than on a key the fixture forgot — which
	# would leave the test green for the wrong reason the next time look.json grows.
	python3 - "$BATS_TEST_DIRNAME/../look.json" "$look" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["colour"]["saturation"] = "1.27,metadata=print:file=/tmp/pwned"
json.dump(d, open(sys.argv[2], "w"))
PY
	LOOK_FILE="$look" GRADE_WORK_DIR="$work" MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "rendered with a non-numeric saturation"
	[[ "$output" == *"must be numeric"* ]] || fail "gave no reason: $output"
}

# --- the event stream ---------------------------------------------------------
# The app drives this engine, and it cannot parse prose written for a person: the human lines are
# deliberately reworded whenever the wording is wrong, which is exactly what a consumer must not
# depend on. So JSON=1 emits one object per line and every refusal names a code on stderr.
#
# What these tests pin is the CONTRACT, not the wording: stdout is machine-readable and nothing
# else, the report still contains the human lines, and each refusal is named.

@test "JSON=1 puts nothing but parseable objects on stdout" {
	local work="$BATS_TEST_TMPDIR/json-dry"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[ -n "$output" ] || fail "JSON=1 produced no events at all"
	# Every line, or the stream is not a stream.
	printf '%s\n' "$output" | _json_lines || fail "stdout was not one JSON object per line:$output"
	# This test was merged RED, because a truncated read of the suite output was mistaken for a
	# pass. What it caught on the first honest run was check_disk_space writing its verdict to
	# stdout, so the first line a consumer saw was not JSON at all.
	[[ "$output" == *'"event":"run_start"'* ]] || fail "no run_start event: $output"
	[[ "$output" == *'"event":"clip_planned"'* ]] || fail "no clip_planned event: $output"
	[[ "$output" == *'"event":"run_done"'* ]] || fail "no run_done event: $output"
}

@test "JSON=1 keeps the human lines in the report rather than dropping them" {
	# The report is what a person reads afterwards, so it is never the half that gets dropped. This
	# is the property that lets a consumer own stdout without anything being lost.
	local work="$BATS_TEST_TMPDIR/json-report"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" != *"clip(s)"* ]] || fail "a human line reached stdout under JSON=1: $output"
	local report
	report=$(ls "$work"/dist/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report was written: $output"
	grep -q "clip(s)" "$report" || fail "the report lost its header line"
	grep -q "gamma=" "$report" || fail "the report lost the per-clip plan"
}

# The report is what a slow or broken render is debugged from afterwards, so what it records has to
# come out of a REAL render: a DRY run never times an encode and never builds the graph. HEIGHT=128
# is what lets a 72x128 fixture finish the delivery chain; at 1080x1920 it fails reinitialising.
# bats test_tags=slow
@test "the run report records the machine, the knobs, the graph and the timing of a real render" {
	local work="$BATS_TEST_TMPDIR/report-proof"
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_mid.mov" "$work/src/CLIP.mov"
	# JSON=1 so the same run also proves none of it leaks onto the event stream.
	JSON=1 HEIGHT=128 PROOF=0.5 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "render failed: $output $stderr"
	[[ "$output" != *"took"* ]] || fail "a report line reached the event stream: $output"
	local report
	report=$(ls "$work"/dist/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report was written: $output"
	grep -qE '^ffmpeg: +ffmpeg version' "$report" || fail "no ffmpeg version: $(cat "$report")"
	grep -qE '^machine: .*[0-9]+ cores' "$report" || fail "no machine line: $(cat "$report")"
	grep -qE '^look: +.*look\.json sha256:[0-9a-f]{16}$' "$report" || fail "no look hash: $(cat "$report")"
	grep -qE '^knobs: .*deliverables=reels .*height=128 .*proof=0\.5 ' "$report" || fail "no knobs: $(cat "$report")"
	grep -qE 'source: 72x128 at 24/1 fps, 2\.0+s, 48 frames' "$report" || fail "no source facts: $(cat "$report")"
	grep -qE 'exposure probe took [0-9]+\.[0-9]{3}s$' "$report" || fail "probe untimed: $(cat "$report")"
	grep -qE 'tone cube took [0-9]+\.[0-9]{3}s$' "$report" || fail "tone cube untimed: $(cat "$report")"
	# 0.5s at 24fps is 12 frames: counted from the file that landed, not assumed from the source.
	grep -qE 'reels-stories_9x16 encode took [0-9]+\.[0-9]{3}s, 12 frames at [0-9.]+ fps, [0-9.]+x realtime, [0-9.]+ Mbit/s' \
		"$report" || fail "no encode speed: $(cat "$report")"
	grep -qE -- '--- graph [0-9]+ \(reels-stories_9x16 encode, -filter_complex\) ---' "$report" \
		|| fail "no delimited filter graph: $(cat "$report")"
	grep -qE '^\[0:v\]lut3d=.*blend=all_mode=grainmerge:shortest=1\[o\]$' "$report" \
		|| fail "the graph was not recorded whole: $(cat "$report")"
	grep -qE '^finished .*, wall time [0-9]+\.[0-9]{3}s$' "$report" || fail "no wall time: $(cat "$report")"
	grep -qE '^  encode +[0-9]+\.[0-9]{3}s$' "$report" || fail "no phase summary: $(cat "$report")"
}

@test "the run report times a preview frame and records its graph" {
	local work="$BATS_TEST_TMPDIR/report-frame"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "frame failed: $output"
	local report
	report=$(ls "$work"/dist/reports/run-*.txt 2>/dev/null | head -1) || true
	[ -n "$report" ] || fail "no run report was written: $output"
	grep -qE 'frame render took [0-9]+\.[0-9]{3}s' "$report" || fail "frame untimed: $(cat "$report")"
	grep -qE -- '--- graph [0-9]+ \(frame, -filter_complex\) ---' "$report" || fail "no frame graph: $(cat "$report")"
	grep -qE '^  frame render +[0-9]+\.[0-9]{3}s$' "$report" || fail "no phase summary: $(cat "$report")"
}

@test "fmt_ms formats whole minutes without losing the milliseconds" {
	[ "$(fmt_ms 4217)" = "4.217s" ] || fail "got $(fmt_ms 4217)"
	[ "$(fmt_ms 7)" = "0.007s" ] || fail "got $(fmt_ms 7)"
	[ "$(fmt_ms 192004)" = "3m12.004s" ] || fail "got $(fmt_ms 192004)"
}

@test "the YAVG placeholder does not produce invalid JSON" {
	# MATCH=0 leaves YAVG as a literal "-", which a laxer numeric test emits bare as `"yavg":-`.
	# One path, invalid on that path only, and nothing else in the suite would have run it.
	local work="$BATS_TEST_TMPDIR/json-dash"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *'"yavg":"-"'* ]] || fail "expected a quoted placeholder: $output"
}

@test "every refusal names a code on stderr, beside the human sentence" {
	local work="$BATS_TEST_TMPDIR/codes"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/A.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/B.mov"

	# A Feed crop across several clips: the offset is a per-clip framing call.
	DELIVERABLES=reels,feed GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"REFUSING: 'feed' crops"* ]] || fail "the human sentence was replaced, not kept"

	# A missing argument, and no arguments at all.
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/NOPE.mov"
	[[ "$output" == *"GRADE_CODE=REFUSE_NOT_FOUND"* ]] || fail "unnamed not-found: $output"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh"
	[[ "$output" == *"GRADE_CODE=REFUSE_NO_ARGS"* ]] || fail "unnamed usage error: $output"
}

@test "a skipped clip and a missing transform are both named" {
	local work="$BATS_TEST_TMPDIR/codes2"
	mkdir -p "$work/src"
	cp "$FIXTURES/landscape_tagged.mov" "$work/src/WIDE.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/TALL.mov"
	# STAB=1 with no transform is the degraded state the engine already prints about; a wrapper has
	# to be able to surface it, because it is the one decision that costs ~65s per clip to get
	# wrong and it used to be made silently.
	DRY=1 MATCH=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GRADE_CODE=REFUSE_NOT_PORTRAIT"* ]] || fail "unnamed skip: $output"
	[[ "$output" == *"GRADE_CODE=NO_TRANSFORM"* ]] || fail "unnamed missing transform: $output"
}

@test "the event stream accounts for every clip in the run" {
	# A wrapper drives a queue off these events, so a dropped one shows up as a clip that never
	# finishes. One skipped and one planned, from a folder argument.
	local work="$BATS_TEST_TMPDIR/json-batch"
	mkdir -p "$work/src"
	cp "$FIXTURES/landscape_tagged.mov" "$work/src/WIDE.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/TALL.mov"
	JSON=1 DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src"
	[ "$status" -eq 0 ]
	local planned skipped
	planned=$(printf '%s\n' "$output" | grep -c '"event":"clip_planned"' || true)
	skipped=$(printf '%s\n' "$output" | grep -c '"event":"clip_skipped"' || true)
	[ "$planned" -eq 1 ] || fail "expected 1 clip_planned, got $planned:$output"
	[ "$skipped" -eq 1 ] || fail "expected 1 clip_skipped, got $skipped:$output"
	[[ "$output" == *'"skipped":1'* ]] || fail "run_done did not count the skip: $output"
}

@test "a render reports progress, through the one chokepoint every path uses" {
	# render_delivery is where grade.sh, 03-final.sh and the proof path all end up, so a bar in the
	# app needs instrumenting exactly here and nowhere else. Every ffmpeg call in this pipeline runs
	# at -v error and none used -progress, so there was no signal at all to read.
	local out="$BATS_TEST_TMPDIR/prog.mp4"
	JSON=1 run render_delivery "$out" "encode" \
		-y -f lavfi -i "color=c=gray:s=72x128:d=1:r=24" \
		-filter_complex "[0:v]${DELIVERY_SETPARAMS}[o]" -map "[o]" \
		-c:v libx264 -pix_fmt yuv420p
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	[[ "$output" == *'"event":"progress"'* ]] || fail "no progress events: $output"
	[[ "$output" == *'"state":"end"'* ]] || fail "the stream never reported completion: $output"
	printf '%s\n' "$output" | _json_lines || fail "progress broke the one-object-per-line contract:$output"
}

@test "a failed render reports and cleans up identically on both paths" {
	# The JSON path pipes ffmpeg, which moves the exit status out of $? and into PIPESTATUS. Taken
	# the naive way, `pipefail` aborts the function at the pipeline instead of returning: the caller
	# gets a bare abort rather than a verdict, and the staging file is left for the next run.
	#
	# RUN UNDER PRODUCTION CONDITIONS, not through bats `run`. `run` disables errexit so it can
	# capture a status, which hides this entire failure class — the first version of this test
	# stayed green against the naive code for exactly that reason. A subshell that sources lib.sh
	# gets lib.sh's own `set -euo pipefail`, which is what grade.sh actually renders under.
	local out="$BATS_TEST_TMPDIR/keep.mp4" mode rc text
	ffmpeg -v error -y -f lavfi -i "color=c=red:s=72x128:d=0.1:r=24" -frames:v 1 \
		-c:v libx264 -pix_fmt yuv420p "$out"
	local before; before=$(md5 -q "$out")
	for mode in 0 1; do
		rc=0
		text=$(JSON=$mode bash -c '
			source "$1/lib.sh"
			render_delivery "$2" doomed -y -f lavfi -i "color=c=gray:s=72x128:d=0.1:r=24" \
				-filter_complex "[0:v]nosuchfilter[o]" -map "[o]" -c:v libx264
		' _ "$SCRIPTS" "$out" 2>&1) || rc=$?
		[ "$rc" -ne 0 ] || fail "JSON=$mode: a broken graph reported success"
		[ "$(md5 -q "$out")" = "$before" ] || fail "JSON=$mode: the existing file was damaged"
		[[ "$text" == *"doomed FAILED (ffmpeg error)"* ]] \
			|| fail "JSON=$mode: no verdict, just an abort: $text"
		[ ! -f "$BATS_TEST_TMPDIR/keep.partial.mp4" ] \
			|| fail "JSON=$mode: a staging file was left behind"
	done
}

# --- the preview frame --------------------------------------------------------
# The app's exact preview. It exists because a slider has to be judged against what the render
# actually produces, and the alternative it replaced — the Bench's pre-baked JPEG — bypassed both
# the real CST and the look LUT, so it mispredicted every reading.

@test "FRAME renders one still through the grade chain and no deliverable" {
	local work="$BATS_TEST_TMPDIR/frame"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	local png="$work/dist/frames/CLIP_t0s_graded.png"
	[ -s "$png" ] || fail "no preview frame at $png: $output"
	run ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height \
		-of default=nw=1:nk=1 "$png"
	[[ "$output" == *"png"* ]] || fail "not a PNG: $output"
	# A preview is not a delivery. Nothing may land where someone uploads from.
	[ -z "$(ls -A "$work/dist/03-final" 2>/dev/null)" ] || fail "FRAME wrote a deliverable"
}

@test "FRAME_STAGE=source gives the picture with no grade on it at all" {
	# The app's live preview grades this frame itself, so that the correction stage — which runs
	# BEFORE Apple's conversion and therefore cannot be recovered from a converted frame — follows
	# a slider too. If this ever returned the graded frame the preview would apply the whole chain
	# twice and look plausible while being wrong.
	local work="$BATS_TEST_TMPDIR/stage"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 FRAME_STAGE=source GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	local graded="$work/dist/frames/CLIP_t0s_graded.png"
	local source="$work/dist/frames/CLIP_t0s_source.png"
	[ -s "$graded" ] || fail "no graded frame: $output"
	# SEPARATE FILES. One name for both stages meant the second render silently replaced the first,
	# which is how a test in the Swift suite once compared a frame against itself.
	[ -s "$source" ] || fail "no source frame: $output"
	! cmp -s "$graded" "$source" || fail "the source stage rendered the graded chain"
}

@test "FRAME_STAGE refuses a value that is neither stage" {
	# A work dir of its own: without one a broken refusal would render into the repo's dist/.
	local work="$BATS_TEST_TMPDIR/frame-stage"
	mkdir -p "$work"
	run env GRADE_WORK_DIR="$work" FRAME=0 FRAME_STAGE=halfway "$SCRIPTS/grade.sh" "$FIXTURES/portrait_tagged.mov"
	[ "$status" -ne 0 ] || fail "an unknown stage was accepted"
	[[ "$output" == *"FRAME_STAGE must be 'graded' or 'source'"* ]] || fail "not refused by the guard: $output"
	[[ "$output" == *"REFUSE_FRAME_STAGE"* ]] || fail "no refusal code: $output"
	[ ! -d "$work/dist" ] || fail "created output before refusing the stage"
}

@test "FRAME and PROOF together are refused rather than silently resolved" {
	local work="$BATS_TEST_TMPDIR/frame-proof"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=1 PROOF=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "accepted both modes at once"
	[[ "$output" == *"GRADE_CODE=REFUSE_PROOF_AND_FRAME"* ]] || fail "unnamed refusal: $output"
}

@test "FRAME announces where the still landed, for a consumer that has to load it" {
	local work="$BATS_TEST_TMPDIR/frame-json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	JSON=1 FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run --separate-stderr "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"event":"frame"'* ]] || fail "no frame event: $output"
	[[ "$output" == *'"path":"'*"CLIP_t0s_graded.png"* ]] || fail "the event did not name the file: $output"
	printf '%s\n' "$output" | _json_lines || fail "the frame event broke the stream contract:$output"
}

@test "FRAME does not pay for a stabilisation pass it cannot show" {
	# vidstabdetect costs ~65s per clip and the still has no warp in it. A preview that waited for
	# that would not be a preview.
	local work="$BATS_TEST_TMPDIR/frame-stab"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 STAB=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[ ! -f "$work/dist/stab/CLIP.trf" ] || fail "FRAME ran the detect pass anyway"
	[[ "$output" != *"stabilising from"* ]] || fail "FRAME claimed to stabilise a still: $output"
}

@test "the tone generator writes the same curve to stdout as to a file" {
	# The preview regenerates this curve on every slider move and wants it in memory. If the two
	# paths could differ, the preview would be predicting a curve the render never uses — and the
	# whole reason the generator is subprocessed rather than ported is that there is one curve.
	local f="$BATS_TEST_TMPDIR/tone.cube"
	run "$SCRIPTS/make-tone-lut.py" "$f" --gamma 2.02 --pivot 0.39 --contrast 1.09 \
		--toe 0 --shoulder 0.1 --black 0.025
	[ "$status" -eq 0 ]
	run --separate-stderr "$SCRIPTS/make-tone-lut.py" --stdout --gamma 2.02 --pivot 0.39 \
		--contrast 1.09 --toe 0 --shoulder 0.1 --black 0.025
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/from-stdout.cube"
	cmp "$f" "$BATS_TEST_TMPDIR/from-stdout.cube" \
		|| fail "the stdout curve is not the curve that gets rendered"
}

@test "the tone generator keeps its commentary out of the curve" {
	# A progress line mixed into the table is read as an entry by whatever parses it.
	run --separate-stderr "$SCRIPTS/make-tone-lut.py" --stdout --gamma 1 --pivot 0.5 \
		--contrast 1 --toe 0 --shoulder 0 --black 0
	[ "$status" -eq 0 ]
	[[ "$output" == TITLE* ]] || fail "stdout did not begin with the cube's TITLE: ${output:0:80}"
	[[ "$stderr" == *"stdout"* ]] || fail "no confirmation on stderr: $stderr"
	# `grep -qv` would have been the obvious assertion and is wrong under pipefail: -q closes the
	# pipe on the first match, printf dies of SIGPIPE, and the pipeline reports 141 whatever the
	# content was. Negate a positive match instead, which reads the whole input when it passes.
	! printf '%s\n' "$output" | grep -q '^wrote' || fail "commentary leaked into the curve"
}

@test "the tone generator refuses an ambiguous destination" {
	# Every tone flag is given, so the destination is the only thing left to refuse — the generator
	# also refuses a missing tone flag, and status alone cannot tell the two apart.
	local tone="--gamma 1 --pivot 0.5 --contrast 1 --toe 0 --shoulder 0 --black 0"
	# shellcheck disable=SC2086
	run "$SCRIPTS/make-tone-lut.py" "$BATS_TEST_TMPDIR/x.cube" --stdout $tone
	[ "$status" -ne 0 ] || fail "accepted both a file and stdout"
	[[ "$output" == *"exactly one of OUT or --stdout"* ]] || fail "not refused at the destination: $output"
	[ ! -e "$BATS_TEST_TMPDIR/x.cube" ] || fail "wrote the file anyway"
	# shellcheck disable=SC2086
	run "$SCRIPTS/make-tone-lut.py" $tone
	[ "$status" -ne 0 ] || fail "accepted neither a file nor stdout"
	[[ "$output" == *"exactly one of OUT or --stdout"* ]] || fail "not refused at the destination: $output"
}

# --- stale transforms ---------------------------------------------------------
# A transform is measured from the DECODED source. If the source changes, the transform describes
# motion in frames that no longer exist, and applying it makes the warp fight the footage.

@test "03-final refuses a stale transform rather than delivering unstabilised" {
	# This stage has no detect pass, so the alternative is shipping a file that looks finished and
	# quietly lacks the stabilisation someone asked for. The warning it used to print sat among a
	# dozen other lines and the render went ahead regardless.
	local work="$BATS_TEST_TMPDIR/stale-final"
	_stale_transform "$work"
	mkdir -p "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP reels
	[ "$status" -ne 0 ] || fail "delivered against a stale transform"
	# Assert the REFUSAL's own words and that the render was never attempted. A synthetic fixture
	# cannot complete the delivery chain, so `status != 0` and an empty output folder are true
	# whether or not the guard fired — written that way, this test passed with the guard removed.
	[[ "$output" == *"REFUSING: stale transform"* ]] || fail "not refused by the guard: $output"
	[[ "$output" != *"encode"* ]] || fail "reached the render despite the stale transform: $output"
	[[ "$output" == *"GRADE_CODE=STALE_TRANSFORM"* ]] || fail "unnamed refusal: $output"
}

@test "ACCEPT_STALE proceeds past the refusal as a decision someone made" {
	# Scoped to the GUARD, not to the render. A 72x128 synthetic fixture cannot complete the
	# delivery chain — it fails reinitialising filters on the way to 1080x1920 — so asserting a
	# successful delivery here would be asserting something about the fixture. What this pins is
	# that the refusal is skipped, said out loud, and the render is attempted.
	local work="$BATS_TEST_TMPDIR/stale-ok"
	_stale_transform "$work"
	mkdir -p "$work/dist/02-graded"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/02-graded/CLIP_graded.mov"
	ACCEPT_STALE=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/03-final.sh" CLIP reels
	[[ "$output" == *"accepted via ACCEPT_STALE=1"* ]] || fail "said nothing about it: $output"
	[[ "$output" != *"REFUSING"* ]] || fail "refused despite ACCEPT_STALE=1: $output"
	[[ "$output" == *"encode"* ]] || fail "never reached the render: $output"
}

@test "a dry run says a stale transform will be recomputed, not ignored" {
	# grade.sh's stale branch is only reachable in a dry run, because a real run recomputes it a
	# few lines earlier. The message said "rendering unstabilised", which is what neither case
	# does — and this is the one decision in a plan that costs ~65s per clip to get wrong.
	local work="$BATS_TEST_TMPDIR/stale-dry"
	_stale_transform "$work"
	DRY=1 MATCH=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" == *"will recompute"* ]] || fail "did not say what a real run would do: $output"
	[[ "$output" != *"rendering unstabilised"* ]] || fail "still claims it renders unstabilised"
}

# --- choosing a look ----------------------------------------------------------
# The look LUT was a constant in lib.sh. The app offers it as a choice, so it is a look value in
# look.json like saturation is, and "none" means the filter leaves the graph rather than being
# pointed at an identity cube.

@test "resolve_look_lut finds a cube by its stem" {
	local root; root="$BATS_TEST_DIRNAME/.."
	run resolve_look_lut kodak_portra_400_nc "$root"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/luts/looks/kodak_portra_400_nc.cube" ]] || fail "wrong path: $output"
	[ -f "$output" ] || fail "resolved to a file that does not exist: $output"
}

@test "resolve_look_lut treats none as no look at all" {
	run resolve_look_lut none "$BATS_TEST_DIRNAME/.."
	[ "$status" -eq 0 ]
	[ -z "$output" ] || fail "none should resolve to nothing, got: $output"
}

@test "resolve_look_lut refuses a cube that is not there, and says what is" {
	run resolve_look_lut fuji_something "$BATS_TEST_DIRNAME/.."
	[ "$status" -ne 0 ] || fail "accepted a look that does not exist"
	[[ "$output" == *"not found"* ]] || fail "no reason given: $output"
	[[ "$output" == *"kodak_portra_400_nc"* ]] || fail "did not list what is available: $output"
}

@test "resolve_look_lut refuses a path carrying filter syntax" {
	run resolve_look_lut "luts/looks/x',metadata=print:file=/tmp/x.cube" "$BATS_TEST_DIRNAME/.."
	[ "$status" -ne 0 ] || fail "accepted a path that would close ffmpeg's quoting"
	# The path does not exist either, so the not-found branch refuses it too: status alone passed
	# with the syntax guard switched off.
	[[ "$output" == *"contains filter syntax"* ]] || fail "refused, but only as not found: $output"
}

@test "the grade chain leaves the look filter out when there is no look" {
	# Not an identity cube: an identity lookup pays interpolation error on every pixel for no
	# change, and the coarse grid these film cubes use pays a visible amount of it.
	LOOK_LUT="" run grade_chain /tmp/tone.cube 1.27 0.005
	[ "$status" -eq 0 ]
	# No 3D lookup at all, not merely one pointing somewhere else. Asserting on the path was the
	# weaker version and it stayed green against a chain that emitted `lut3d=file=''` — a filter
	# with an empty filename, which is worse than either intended behaviour. Found by mutation.
	[[ "$output" != *"lut3d="* ]] || fail "a look filter survived: $output"
	# One lookup left, and it is the tone curve on the luma plane.
	[[ "$output" == *"lut1d=file='/tmp/tone.cube'"* ]] || fail "lost the tone curve: $output"
	[[ "$output" == *"mergeplanes=0x001112"* ]] || fail "lost the luma-only merge: $output"
}

@test "the grade chain names the chosen look when there is one" {
	LOOK_LUT="/tmp/portra.cube" run grade_chain /tmp/tone.cube 1.27 0.005
	[ "$status" -eq 0 ]
	[[ "$output" == *"lut3d=file='/tmp/portra.cube':interp=tetrahedral,"* ]] \
		|| fail "the look is not in the chain: $output"
}

@test "look.json is where the look LUT is chosen" {
	# The whole point: a look.json written by the app changes the look LUT too, without editing a
	# script. A cube nothing else in the repo would pick.
	local work="$BATS_TEST_TMPDIR/lookchoice" look="$BATS_TEST_TMPDIR/other.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	python3 - "$BATS_TEST_DIRNAME/../look.json" "$look" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["look"]["lut"] = "kodak_portra_400_nc_NOPE"
json.dump(d, open(sys.argv[2], "w"))
PY
	LOOK_FILE="$look" GRADE_WORK_DIR="$work" DRY=1 MATCH=0 STAB=0 \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "a look.json naming a missing cube rendered anyway"
	[[ "$output" == *"not found"* ]] || fail "no reason given: $output"
}

# bats test_tags=slow
@test "LOOK=none renders a visibly different still than the shipped look" {
	# End to end, through the real chain, because a string test cannot tell whether the filter that
	# left the graph was the one doing the work.
	local work="$BATS_TEST_TMPDIR/lookdiff"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	mv "$work/dist/frames/CLIP_t0s_graded.png" "$work/with-look.png"
	LOOK=none FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	! cmp -s "$work/with-look.png" "$work/dist/frames/CLIP_t0s_graded.png" \
		|| fail "LOOK=none produced the same pixels as the shipped look"
}

# --- delivery shape -----------------------------------------------------------
# The output sizes were two literals in the render calls and the crop window was a third. The app
# offers height, aspect and frame rate as choices, so they are computed — and the two that can be
# asked for impossibly are refused before a render starts rather than failing inside ffmpeg.

@test "crop_prefix computes the window from the source rather than assuming 2160x3840" {
	run crop_prefix 2160 3840 4 5 750
	[ "$status" -eq 0 ]
	[ "$output" = "crop=2160:2700:0:750," ] || fail "wrong window: $output"
	# A different source width must move the window with it.
	run crop_prefix 1080 1920 4 5 100
	[ "$status" -eq 0 ]
	[ "$output" = "crop=1080:1350:0:100," ] || fail "window did not follow the source: $output"
}

@test "crop_prefix refuses an offset past the frame edge, before any render starts" {
	# 03-final.sh claimed the portrait guard covered this. It does not: that guard only compares
	# width against height. Unvalidated, the offset failed inside ffmpeg seconds into a render.
	run crop_prefix 2160 3840 4 5 1141
	[ "$status" -ne 0 ] || fail "accepted an offset one pixel past the edge"
	[[ "$output" == *"0..1140"* ]] || fail "did not say what the bound is: $output"
	run crop_prefix 2160 3840 4 5 -1
	[ "$status" -ne 0 ] || fail "accepted a negative offset"
	run crop_prefix 2160 3840 4 5 1140
	[ "$status" -eq 0 ] || fail "refused the last valid offset: $output"
}

@test "the sharpener's radius follows the output height" {
	# Its 5x5 was measured at 1080x1920 and the radius is in PIXELS, so at another height it
	# sharpens a different real-world detail size.
	run delivery_image_chain 1080 1920 "" ""
	[[ "$output" == *"unsharp=5:5:0.4"* ]] || fail "1920 should be the measured radius: $output"
	run delivery_image_chain 2160 3840 "" ""
	[[ "$output" == *"unsharp=11:11:0.4"* ]] || fail "radius did not scale: $output"
	# unsharp rejects a radius below 3, so a small output must not ask for one.
	run delivery_image_chain 360 640 "" ""
	[[ "$output" == *"unsharp=3:3:0.4"* ]] || fail "radius went below the floor: $output"
}

@test "fps_filter accepts an integer relation and refuses retiming" {
	run fps_filter 24/1 24
	[ "$status" -eq 0 ]
	[ -z "$output" ] || fail "the same rate should need no filter: $output"
	run fps_filter 24/1 12
	[ "$status" -eq 0 ]
	[ "$output" = ",fps=12" ] || fail "halving should drop whole frames: $output"
	run fps_filter 24/1 48
	[ "$status" -eq 0 ]
	[ "$output" = ",fps=48" ] || fail "doubling should repeat whole frames: $output"
	# The case that tempts people and the one that judders.
	run fps_filter 24/1 30
	[ "$status" -ne 0 ] || fail "accepted 24 to 30, which needs retiming"
	[[ "$output" == *"judder"* ]] || fail "gave no reason: $output"
}

@test "a frame rate that needs retiming skips the clip rather than delivering judder" {
	local work="$BATS_TEST_TMPDIR/fps"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	FPS_OUT=30 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *"GRADE_CODE=REFUSE_FPS_RETIME"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"needs retiming"* ]] || fail "said nothing useful: $output"
	[ -z "$(ls -A "$work/dist/03-final" 2>/dev/null)" ] || fail "delivered anyway"
}

@test "require_portrait hands back the size it measured" {
	# So a caller that needs the source's dimensions does not decode a second frame to ask again.
	run require_portrait "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ]
	[ "$output" = "72 128" ] || fail "expected the measured size, got: $output"
}
# --- deliverables as data ------------------------------------------------------
# A deliverable was a `case` branch carrying its own pixel sizes, so the set was closed at two and
# every shape in it assumed this camera's frame. These cover the replacement: the shapes are data,
# the geometry is computed from the source that is actually on disk, and the two presets still
# resolve to exactly the numbers the branches hardcoded.

@test "the presets still resolve to the sizes their case branches hardcoded" {
	# The byte-identity guard, in the cheap form. tests/render-golden.sh renders the default image
	# and compares, which takes a real render; this fails in milliseconds and names which number moved.
	run deliverable_spec reels
	[ "$output" = "reels 9 16 - reels-stories_9x16" ] || fail "reels moved: $output"
	run deliverable_spec feed
	[ "$output" = "feed 4 5 - feed_4x5" ] || fail "feed moved: $output"
	[ "$(deliverable_height 1080 9 16)" = "1920" ] || fail "reels is no longer 1080x1920"
	[ "$(deliverable_height 1080 4 5)" = "1350" ] || fail "feed is no longer 1080x1350"
}

@test "a deliverable can be an arbitrary shape, not one of two names" {
	run deliverable_spec square:1:1
	[ "$status" -eq 0 ] || fail "refused a custom shape: $output"
	[ "$output" = "square 1 1 - square_1x1" ] || fail "unexpected spec: $output"
	run deliverable_spec wide:16:9:400
	[ "$output" = "wide 16 9 400 wide_16x9" ] || fail "the per-deliverable offset was lost: $output"
	[ "$(deliverable_height 1080 1 1)" = "1080" ] || fail "1:1 is not square"
}

@test "a deliverable name that would reach the filter graph is refused" {
	# It becomes a path component and an ffmpeg argument, exactly like a clip name, so it goes
	# through the same guard rather than a weaker one written beside it.
	run deliverable_spec 'a/b:1:1'
	[ "$status" -ne 0 ] || fail "accepted a name containing a path separator"
	run deliverable_spec "q'x:1:1"
	[ "$status" -ne 0 ] || fail "accepted a name containing filter syntax"
	run deliverable_spec nope
	[ "$status" -ne 0 ] || fail "accepted an unknown preset"
	[[ "$output" == *"name:aspect-w:aspect-h"* ]] || fail "did not say what it wanted: $output"
	run deliverable_spec 'a:0:1'
	[ "$status" -ne 0 ] || fail "accepted a zero aspect term"
}

@test "a deliverable that is already the source's shape takes no crop filter" {
	# THE BYTE-IDENTITY RULE. Every deliverable resolves its crop through crop_prefix now, where
	# the 9:16 one used to be handed a literal empty string by its own branch. A no-op
	# `crop=2160:3840:0:0` would render the same picture and still change the graph, which is a
	# difference tests/render-golden.sh sees.
	run crop_prefix 2160 3840 9 16 750
	[ "$status" -eq 0 ] || fail "refused the source's own shape: $output"
	[ -z "$output" ] || fail "emitted a crop for a deliverable that does not crop: $output"
	# ...and a shape that IS a crop still gets one, computed from the source rather than assumed.
	run crop_prefix 2160 3840 4 5 750
	[ "$output" = "crop=2160:2700:0:750," ] || fail "the 4:5 window moved: $output"
}

@test "whether a deliverable crops is decided by the source, not by its name" {
	# 4:5 is a crop of a 9:16 master and the WHOLE FRAME of a 4:5 one. The refusal that uses this
	# fires before any clip is opened, so it cannot ask crop_prefix — it has no offset yet.
	deliverable_crops "2160 3840" 9 16 && fail "said 9:16 crops a 9:16 source"
	deliverable_crops "2160 3840" 4 5 || fail "said 4:5 does not crop a 9:16 source"
	deliverable_crops "2160 2700" 4 5 && fail "said 4:5 crops a 4:5 source"
	# An unmeasurable source is ASSUMED to crop: the guard then fires when it need not have, which
	# costs a re-run, where guessing the other way costs a batch of silently reframed files.
	deliverable_crops "" 9 16 || fail "an unmeasurable source was assumed safe"
}

@test "a cropped deliverable across several clips is refused, and named" {
	local work="$BATS_TEST_TMPDIR/crop"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/A.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/B.mov"
	DELIVERABLES=reels,feed MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -ne 0 ] || fail "reframed a batch from one clip's composition"
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"'feed' crops"* ]] || fail "did not name the deliverable: $output"
	# The UNCROPPED one must not trip it, or every folder run would refuse.
	DELIVERABLES=reels MATCH=0 STAB=0 DRY=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov"
	[ "$status" -eq 0 ] || fail "an uncropped deliverable was refused across a batch: $output"
}

@test "a deliverable whose crop cannot fit the source is refused before it is delivered" {
	local work="$BATS_TEST_TMPDIR/toofit"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	# 1:4 is TALLER than the 9:16 source, so there is no window to take.
	DELIVERABLES=tall:1:4:0 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[[ "$output" == *"does not fit"* ]] || fail "gave no reason: $output"
	[ -z "$(ls -A "$work/dist/03-final" 2>/dev/null)" ] || fail "delivered anyway"
}

@test "a cropping deliverable with no offset is refused even for a single clip" {
	# THE DEFAULT IS GONE. It was 750 — IMG_0609's composition — which meant a single-clip run
	# silently framed every other clip in the world to one afternoon's parking ceiling. The batch
	# case was already refused; this is the same rule applied to the case the default existed for.
	local work="$BATS_TEST_TMPDIR/nodefault"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/ONE.mov"
	DELIVERABLES=feed MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/ONE.mov"
	[ "$status" -ne 0 ] || fail "invented an offset for a single clip: $output"
	[[ "$output" == *"GRADE_CODE=REFUSE_CROP_NO_OFFSET"* ]] || fail "unnamed refusal: $output"
	[[ "$output" == *"no sensible"* ]] || fail "did not say why there is no default: $output"
	[ -z "$(ls -A "$work/dist/03-final" 2>/dev/null)" ] || fail "delivered anyway"
	# An explicit offset still works, and so does an explicit "I do not need one".
	DELIVERABLES=feed CROP_Y=centre MATCH=0 STAB=0 DRY=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/ONE.mov"
	[ "$status" -eq 0 ] || fail "CROP_Y=centre was not accepted: $output"
}

@test "centre is resolved against each clip's own frame, not once for the run" {
	# A fixed pixel offset cannot be right for two differently shaped sources; a centred one is
	# right for both. That is the whole reason centre is available and 750 is not.
	run crop_prefix 2160 3840 4 5 centre
	[ "$output" = "crop=2160:2700:0:570," ] || fail "not centred on a 3840-tall source: $output"
	run crop_prefix 2160 2880 4 5 centre
	[ "$output" = "crop=2160:2700:0:90," ] || fail "centre did not follow the source height: $output"
	# Even, because an odd vertical offset shifts the chroma siting on 4:2:0.
	run crop_prefix 2160 3841 4 5 centre
	[ "${output##*:}" = "570," ] || fail "centre landed on an odd row: $output"
}

@test "crop_prefix refuses an offset it was never given, rather than inventing one" {
	# Reachable past the run's up-front check, which reads the first renderable clip: a later clip
	# of another shape can need a crop where that one did not.
	run crop_prefix 2160 3840 4 5 ""
	[ "$status" -ne 0 ] || fail "accepted an empty offset: $output"
	[[ "$output" == *"needs a vertical offset"* ]] || fail "gave no reason: $output"
	[[ "$output" == *"CROP_Y=centre"* ]] || fail "did not say how to say 'no preference': $output"
}

@test "a deliverable's own offset may be centre, and it beats the run's" {
	run deliverable_spec feed:4:5:centre
	[ "$output" = "feed 4 5 centre feed_4x5" ] || fail "centre was not carried: $output"
	run deliverable_spec feed:4:5:nonsense
	[ "$status" -ne 0 ] || fail "accepted a word that is not an offset"
}

# --- the exposure reference ----------------------------------------------------
# MATCH=1 lands every clip on look.json's match.reference_yavg, which is a measurement of one frame
# of one clip of one shoot. MATCH=batch anchors on the run's own median instead. See docs/adr/0011.

# bats test_tags=slow
@test "MATCH=batch anchors on the run's own clips, not on look.json's reference" {
	local work="$BATS_TEST_TMPDIR/batch"
	mkdir -p "$work/src"
	cp "$FIXTURES/probe_dark.mov"   "$work/src/A.mov"
	cp "$FIXTURES/probe_mid.mov"    "$work/src/B.mov"
	cp "$FIXTURES/probe_bright.mov" "$work/src/C.mov"
	MATCH=batch STAB=0 DRY=1 JSON=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A.mov" "$work/src/B.mov" "$work/src/C.mov"
	[ "$status" -eq 0 ] || fail "batch mode failed: $output"
	local reference; reference="$(printf '%s' "$output" | sed -n 's/.*"exposure_reference":\([0-9.]*\).*/\1/p' | head -1)"
	[ -n "$reference" ] || fail "the run did not report what it anchored on: $output"
	# THE MIDDLE CLIP, not the first and not an average of the outer two. B is the median, so it
	# defines the reference and is the one clip left on look.json's own gamma; A and C move.
	local b_yavg; b_yavg="$(printf '%s' "$output" | sed -n 's/.*"clip":"B","source":"[^"]*","yavg":\([0-9.]*\).*/\1/p')"
	[ "$reference" = "$b_yavg" ] || fail "anchored on $reference, but the median clip reads $b_yavg"
	[[ "$output" == *'"clip":"B"'*'"matched":0'* ]] || fail "the median clip was matched off itself: $output"
	[[ "$output" == *'"clip":"A"'*'"matched":1'* ]] || fail "the dark clip was not matched: $output"
	[[ "$output" == *'"clip":"C"'*'"matched":1'* ]] || fail "the bright clip was not matched: $output"
}

@test "MATCH refuses a mode it does not have, rather than picking one" {
	local work="$BATS_TEST_TMPDIR/mode"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	MATCH=yes STAB=0 DRY=1 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "accepted an unknown MATCH mode"
	[[ "$output" == *"GRADE_CODE=REFUSE_MATCH_MODE"* ]] || fail "unnamed refusal: $output"
}

@test "the batch measurements stay aligned with their clips when one is skipped" {
	# The measurements are found BY POSITION, so an early skip that did not advance the index would
	# hand every clip after it the previous clip's exposure — a wrong grade on a file that looks
	# finished, which is the whole failure class this pipeline is built against.
	local work="$BATS_TEST_TMPDIR/align"
	mkdir -p "$work/src"
	# A is skipped for being landscape, and is DARK. B renders, and is BRIGHT. The lower median of
	# the two measurements is A's, so if B reads A's slot it reports the reference exposure back
	# and looks perfectly matched — the wrong grade on a file that looks finished.
	cp "$FIXTURES/probe_dark_landscape.mov" "$work/src/A_skipped.mov"
	cp "$FIXTURES/probe_bright.mov" "$work/src/B_kept.mov"
	MATCH=batch STAB=0 DRY=1 JSON=1 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/A_skipped.mov" "$work/src/B_kept.mov"
	[ "$status" -eq 0 ] || fail "the run failed: $output"
	[[ "$output" == *'"clip":"A_skipped"'*'"code":"REFUSE_NOT_PORTRAIT"'* ]] \
		|| fail "the landscape clip was not skipped: $output"
	local reference b_yavg
	reference="$(printf '%s' "$output" | sed -n 's/.*"exposure_reference":\([0-9.]*\).*/\1/p' | head -1)"
	b_yavg="$(printf '%s' "$output" | sed -n 's/.*"clip":"B_kept","source":"[^"]*","yavg":\([0-9.]*\).*/\1/p')"
	[ -n "$reference" ] || fail "no reference in the event stream: $output"
	[ -n "$b_yavg" ] || fail "no measurement for the kept clip: $output"
	[ "$b_yavg" != "$reference" ] || fail "the kept clip reported the skipped clip's exposure ($b_yavg)"
	[[ "$output" == *'"clip":"B_kept"'*'"matched":1'* ]] \
		|| fail "the kept clip was not matched, so it read the wrong slot: $output"
}

# --- the grade golden ---------------------------------------------------------
# tests/grade-parity.py records ffmpeg's own output in tests/fixtures/grade-golden.json, and
# LiveGradeTests holds Swift's model to it. That makes the golden a claim about a chain, and a claim
# about a chain goes stale the moment the chain moves. It used to hold the browser Bench's
# JavaScript to the same numbers; the Bench is gone and the golden outlived it.
#
# These two guards are the cheap half of that: they need no ffmpeg, so they run everywhere the suite
# runs, and they fail by name rather than leaving the harness to discover it.

@test "the grade golden still describes the chain in lib.sh" {
	# By CONTENT, never mtime: git does not preserve mtime, so on a fresh clone the committed
	# golden always lands newer than lib.sh and would be trusted forever. Same reasoning as
	# ensure_tone_lut's TITLE fingerprint.
	#
	# The fingerprint is COMPUTED BY THE HARNESS that writes it, not re-derived here. This test used
	# to carry its own copy of the normalisation and the hash, which agreed with the harness only
	# for as long as nobody edited either.
	local root have want
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	have="$(python3 -c '
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("parity", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.chain_fingerprint())
' "$root/tests/grade-parity.py")" || fail "could not compute the chain fingerprint: $have"
	want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["chain_fingerprint"])' \
		"$root/tests/fixtures/grade-golden.json")"
	[ "$have" = "$want" ] || fail "the grade chain changed and the golden was not regenerated.
  lib.sh: $have
  golden: $want
  Re-run tests/grade-parity.py --regenerate and say in the commit what moved and why."
}

@test "the grade probe still matches the golden measured on it" {
	local root have want
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	have="$(shasum -a 256 "$root/tests/fixtures/grade-probe.png" | cut -d' ' -f1)"
	want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["probe"]["sha256"])' \
		"$root/tests/fixtures/grade-golden.json")"
	[ "$have" = "$want" ] || fail "the probe image and the golden disagree; regenerate both"
}


@test "the golden records what its tolerances mean, not just what they are" {
	# A number with no rationale beside it is the thing that gets "tidied" to make a run green.
	# Every tolerance in the golden carries its own _why, and the measured grade divergence is far
	# above the curve's one-code-value bar deliberately — that gap is a finding, not a defect.
	local root
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	run python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))["tolerances"]
need = ["curve_code_values", "conversion_floor_code_values", "grade_code_values",
        "grade_worst_by_case", "grade_margin_code_values"]
for k in need:
    if k not in t: sys.exit("golden is missing tolerance %s" % k)
for k in ("_curve_why", "_floor_why", "_grade_why", "_margin_why"):
    if not t.get(k): sys.exit("tolerance %s has no rationale" % k)
if t["conversion_floor_code_values"] > 2:
    sys.exit("the conversion floor is %.2f code values — the ruler is measuring itself"
             % t["conversion_floor_code_values"])
print("ok")
' "$root/tests/fixtures/grade-golden.json"
	[ "$status" -eq 0 ] || fail "$output"
}

@test "--remeasure refuses without a reason" {
	local root probe_sha
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	probe_sha="$(shasum -a 256 "$root/tests/fixtures/grade-probe.png" | cut -d' ' -f1)"

	# Test with no argument
	run python3 "$root/tests/grade-parity.py" --remeasure
	[ "$status" -ne 0 ] || fail "should have refused"
	echo "$output" | grep -q "remeasure requires a non-empty reason" || fail "did not print the refusal message: $output"

	# Verify golden was not changed
	local new_probe_sha
	new_probe_sha="$(shasum -a 256 "$root/tests/fixtures/grade-probe.png" | cut -d' ' -f1)"
	[ "$probe_sha" = "$new_probe_sha" ] || fail "probe was modified by refusal"
}

@test "--remeasure refuses with empty string" {
	local root golden_sha
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	golden_sha="$(shasum -a 256 "$root/tests/fixtures/grade-golden.json" | cut -d' ' -f1)"

	run python3 "$root/tests/grade-parity.py" --remeasure ""
	[ "$status" -ne 0 ] || fail "should have refused empty reason"
	echo "$output" | grep -q "remeasure requires a non-empty reason" || fail "did not print the refusal message: $output"

	# Verify golden was not changed
	local new_golden_sha
	new_golden_sha="$(shasum -a 256 "$root/tests/fixtures/grade-golden.json" | cut -d' ' -f1)"
	[ "$golden_sha" = "$new_golden_sha" ] || fail "golden was modified by refusal"
}

# --- the input correction -----------------------------------------------------
# Exposure, white balance and the CDL wheels, as one generated cube that runs BEFORE Apple's
# conversion — in log, where highlights up to 12x diffuse white still exist. A neutral correction leaves the
# filter out of the graph, because an identity cube still pays interpolation error on every pixel.

@test "the correction generator round-trips Apple's published transfer function" {
	# The formula is published, so this is exact rather than fitted. If it ever stops round-tripping,
	# the maths has been edited rather than the parameters.
	run python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
worst = max(abs(mc.encode(mc.decode(i/1000.0)) - i/1000.0) for i in range(1001))
print("%.1e %.4f" % (worst, mc.decode(1.0)))
' "$SCRIPTS/make-correct-lut.py"
	[ "$status" -eq 0 ] || fail "$output"
	local worst headroom
	worst="${output% *}"; headroom="${output#* }"
	python3 -c "import sys; sys.exit(0 if float('$worst') < 1e-9 else 1)" \
		|| fail "the transfer function no longer round-trips: $worst"
	# 12x diffuse white in linear, about 3.6 stops above it — not twelve stops.
	[ "$headroom" = "12.0000" ] || fail "decode(1.0) should be 12x diffuse white, got $headroom"
}

@test "a neutral correction is reported as neutral, and any move as active" {
	run "$SCRIPTS/make-correct-lut.py" --check-neutral
	[ "$status" -eq 0 ]
	[ "$output" = "neutral" ] || fail "defaults are not neutral: $output"
	for arg in "--exposure 0.1" "--temp 0.1" "--tint 0.1" "--slope 1.1,1,1" \
	           "--offset 0.01,0,0" "--power 1.1,1,1"; do
		# shellcheck disable=SC2086
		run "$SCRIPTS/make-correct-lut.py" --check-neutral $arg
		[ "$output" = "active" ] || fail "$arg reported as $output"
	done
}

@test "the correction cube is skipped entirely when it would do nothing" {
	# The engine must not render every pixel through a lookup that returns it: that costs time, and
	# interpolation error on every pixel of a look nobody changed.
	local work="$BATS_TEST_TMPDIR/neutral"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	[[ "$output" != *"correction:"* ]] || fail "announced a correction that does nothing: $output"
	[ ! -f "$work/dist/.grade-work/correct.cube" ] || fail "generated a cube for a neutral correction"
}

# bats test_tags=slow
@test "an active correction reaches the render and changes the picture" {
	local work="$BATS_TEST_TMPDIR/active" look="$BATS_TEST_TMPDIR/warm.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	python3 - "$BATS_TEST_DIRNAME/../look.json" "$look" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["correct"]["exposure"] = 0.75
json.dump(d, open(sys.argv[2], "w"))
PY
	LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"correction: --exposure 0.75 "* ]] || fail "said nothing about it: $output"
	[ -s "$work/dist/.grade-work/correct.cube" ] || fail "no cube was generated"
	# And it changed the picture. A string test cannot tell whether the filter did anything.
	mv "$work/dist/frames/CLIP_t0s_graded.png" "$work/corrected.png"
	FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ]
	! cmp -s "$work/corrected.png" "$work/dist/frames/CLIP_t0s_graded.png" \
		|| fail "a 0.75 stop exposure correction changed nothing"
}

@test "the correction precedes Apple's conversion in both graphs" {
	# ORDER IS THE DECISION. Apple Log holds highlights up to 12x diffuse white, about 3.6 stops
	# above it, which the Rec.709 cube lands on a display ceiling of 1.0, so a correction applied after it works on display-referred pixels and clips
	# highlights the source still holds. Before it, the same move is the log-domain correction a
	# colourist's wheels perform.
	#
	# A source assertion, like the one that pins the grade chain to one place: the built graph is
	# not printed anywhere, and a render test can only show that the correction did something, not
	# where it sat. Both the delivery graph and the preview must have it ahead of the conversion.
	local n
	#
	# Halation sits between the two: it acts on light, so it follows the exposure the correction set
	# and precedes the conversion that would land every highlight on the same display ceiling.
	n=$(grep -c "CORRECT_PREFIX}\${HALATION_PREFIX}lut3d=file='\${CST}'" "$SCRIPTS/grade.sh" || true)
	[ "$n" -eq 2 ] || fail "expected correction, halation, CST in that order in both graphs, found $n"
	# And nowhere after it.
	! grep -qE "CST\}':interp=tetrahedral,\\\$\{(CORRECT|HALATION)_PREFIX\}" "$SCRIPTS/grade.sh" \
		|| fail "a pre-conversion stage was placed after the conversion"
}

@test "the correction cube is regenerated by content, never by timestamp" {
	# Same reasoning as the tone cube's TITLE: git does not preserve mtime, so a committed cube
	# always lands newer than the file it came from and would be trusted forever.
	local cube="$BATS_TEST_TMPDIR/c.cube"
	run "$SCRIPTS/make-correct-lut.py" "$cube" --exposure 0.5 --size 5
	[ "$status" -eq 0 ]
	run "$SCRIPTS/make-correct-lut.py" "$cube" --exposure 0.5 --size 5
	[[ "$output" == *"already current"* ]] || fail "rewrote a cube that already matched: $output"
	run "$SCRIPTS/make-correct-lut.py" "$cube" --exposure 0.6 --size 5
	[[ "$output" != *"already current"* ]] || fail "kept a cube built at a different exposure"
	grep -q 'exposure=0.6' "$cube" || fail "the cube does not record what it was built at"
}

@test "a cube built at a value that differs past six digits is not trusted as current" {
	# The TITLE is the freshness check, so its number format IS the check. Two generators wrote it
	# with %g, six significant digits: 0.1234567 and 0.1234568 stamped the same TITLE, and the
	# second run kept the cube built at the first. Every generator now goes through cubefile.py.
	local dir="$BATS_TEST_TMPDIR/precise"
	mkdir -p "$dir"
	run "$SCRIPTS/make-correct-lut.py" "$dir/c.cube" --exposure 0.1234567 --size 3
	[ "$status" -eq 0 ] || fail "$output"
	run "$SCRIPTS/make-correct-lut.py" "$dir/c.cube" --exposure 0.1234568 --size 3
	[[ "$output" != *"already current"* ]] || fail "the correction kept a cube built at another exposure"

	run "$SCRIPTS/make-halation-luts.py" "$dir/h" --threshold 1.0000001
	[ "$status" -eq 0 ] || fail "$output"
	run "$SCRIPTS/make-halation-luts.py" "$dir/h" --threshold 1.0000002
	[ "$output" = "wrote halation-threshold.cube" ] || fail "halation kept a cube built at another threshold: $output"

	local tone=(--pivot 0.42 --contrast 1.0 --toe 0 --shoulder 0 --black 0)
	run "$SCRIPTS/make-tone-lut.py" "$dir/t.cube" --gamma 2.0200001 "${tone[@]}"
	[ "$status" -eq 0 ] || fail "$output"
	run "$SCRIPTS/make-tone-lut.py" "$dir/t.cube" --gamma 2.0200002 "${tone[@]}"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" != *"already current"* ]] || fail "the tone curve kept a cube built at another gamma"
}

@test "the correction generator refuses a malformed wheel" {
	# Each refusal asserts its own words. A zero power exits non-zero without the guard too, from the
	# ZeroDivisionError it raises, so a status check alone passed against a removed guard.
	run "$SCRIPTS/make-correct-lut.py" --stdout --slope "1,2"
	[ "$status" -ne 0 ] || fail "accepted a two-value wheel"
	[[ "$output" == *"wants one value or three"* ]] || fail "refused the wheel without saying why: $output"
	run "$SCRIPTS/make-correct-lut.py" --stdout --power "0,1,1"
	[ "$status" -ne 0 ] || fail "accepted a zero power, which is a division by zero"
	[[ "$output" == *"must be positive"* ]] || fail "zero power failed, but not at the guard: $output"
	run "$SCRIPTS/make-correct-lut.py" --stdout --size 200
	[ "$status" -ne 0 ] || fail "accepted an absurd cube size"
	[[ "$output" == *"outside 2..64"* ]] || fail "refused the size without saying why: $output"
}

# Writes a copy of look.json with one jq assignment applied, and prints its path.
_look_with() {  # _look_with <name> <jq-assignment>
	local out="$BATS_TEST_TMPDIR/$1.json"
	jq "$2" "$BATS_TEST_DIRNAME/../look.json" > "$out"
	printf '%s\n' "$out"
}

@test "a correction wheel that cannot be read stops the run rather than dropping the stage" {
	# The generator decides neutrality, and a generator handed a split argument dies of argparse
	# and answers with nothing. Compared as a string, nothing is "not active": the correction was
	# left out of both render paths in silence. Both must refuse instead.
	local work="$BATS_TEST_TMPDIR/badwheel" look
	mkdir -p "$work/src" "$work/dist/01-baseline"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/01-baseline/CLIP_baseline.mov"
	look="$(_look_with badwheel '.correct.slope = "1.2, 1, 1"')"

	LOOK_FILE="$look" DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "grade.sh planned a run without the correction: $output"
	[[ "$output" == *"correct.slope must be numbers separated by commas"* ]] \
		|| fail "grade.sh did not say which value: $output"

	LOOK_FILE="$look" GRADE_WORK_DIR="$work" run "$SCRIPTS/02-grade.sh" CLIP
	[ "$status" -ne 0 ] || fail "02-grade.sh rendered a master without the correction"
	[[ "$output" == *"correct.slope must be numbers separated by commas"* ]] \
		|| fail "02-grade.sh did not say which value: $output"
	[ ! -e "$work/dist/02-graded" ] || fail "02-grade.sh created output before refusing"
}

@test "a look.json that has lost its film look stops the run rather than rendering without one" {
	# resolve_look_lut reads an empty name as "none", which is right for a deliberate empty. The
	# name used to be read inside its argument list, where a missing key BECAME that empty name, so
	# both render paths planned a grade with no film cube and said nothing.
	local work="$BATS_TEST_TMPDIR/nolook" look
	mkdir -p "$work/src" "$work/dist/01-baseline"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	cp "$FIXTURES/portrait_tagged.mov" "$work/dist/01-baseline/CLIP_baseline.mov"
	look="$(_look_with nolook 'del(.look.lut)')"

	LOOK_FILE="$look" DRY=1 MATCH=0 STAB=0 GRADE_WORK_DIR="$work" run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "grade.sh planned a run with no film look: $output"
	[[ "$output" == *"look.json: missing .look.lut"* ]] || fail "grade.sh did not name the key: $output"

	LOOK_FILE="$look" GRADE_WORK_DIR="$work" run "$SCRIPTS/02-grade.sh" CLIP
	[ "$status" -ne 0 ] || fail "02-grade.sh rendered a master with no film look"
	[[ "$output" == *"look.json: missing .look.lut"* ]] || fail "02-grade.sh did not name the key: $output"
	[ ! -e "$work/dist/02-graded" ] || fail "02-grade.sh created output before refusing"
}

@test "encode settings, analysis settings and stage paths are spelled in lib.sh and nowhere else" {
	# Each of these was written into two stage scripts and the byte comparisons render only one of them,
	# so an edit to the other reached files nobody compared: the delivery encode, the ProRes master
	# encode, the stabilisation analysis both entry points cache under one path, the Apple cube's
	# path, and the paths one stage reads that another wrote.
	local offenders
	# The render entry points only. check.sh names Apple's cube and src/ too, to warn that a green run
	# skipped the render tests; it renders nothing and does not source lib.sh.
	offenders=$(grep -nE 'libx264|prores_ks|vidstabdetect|AppleLogToRec709|dist/(stab|01-baseline|02-graded)/|/src/' \
		"$SCRIPTS"/0*.sh "$SCRIPTS"/grade.sh | grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "spelled outside lib.sh:$offenders"
}

@test "every generator's flags are spelled in lib.sh and nowhere else" {
	# The tone block was mapped to flags in two places and the correction's in two, and the copies
	# had drifted by a flag. A flag written at a call site is the start of the next copy.
	local offenders
	offenders=$(grep -nE -- '--(pivot|contrast|shoulder|black|exposure|temp|tint|slope|offset|power|lum-mix) ' \
		"$SCRIPTS"/*.sh | grep -v '/lib\.sh:' | grep -v ':[0-9]*:[[:space:]]*#' || true)
	[ -z "$offenders" ] || fail "spells a generator flag outside lib.sh:$offenders"
}

# --- halation -----------------------------------------------------------------
# A glow computed in linear light between the correction and the conversion. The graph is
# halation_prefix in lib.sh and the cubes come from make-halation-luts.py; the traps both are shaped
# around are in their headers. These tests drive the builder on FLOAT frames written byte for byte,
# because what is under test is what ffmpeg does to exact values, and a YUV fixture would bury that
# under a conversion's own rounding.

# Runs a gbrpf32le frame through a filter chain and prints every sample of the result, one per line,
# planes in ffmpeg's order: G, then B, then R.
_float_through() {  # _float_through <in.raw> <w> <h> <chain>
	ffmpeg -v error -f rawvideo -pix_fmt gbrpf32le -s "${2}x${3}" -i "$1" \
		-filter_complex "[0:v]${4}null[o]" -map "[o]" -f rawvideo -pix_fmt gbrpf32le - \
		| python3 -c 'import sys, struct; d = sys.stdin.buffer.read(); print("\n".join("%.6f" % v for v in struct.unpack("%df" % (len(d) // 4), d)))'
}

@test "an idle halation stage hands back the frame it was given, highlights included" {
	# The stage decodes to linear and encodes back, and two ffmpeg behaviours can quietly wreck
	# that while every picture still looks plausible:
	#   - lut1d ignores a negative DOMAIN_MIN, so the inverse cube reads shifted by 0.056 unless the
	#     linear values are offset to stay positive (measured 20 code values out before the offset);
	#   - `blend` addition, avgblur and boxblur clamp float at 1.0, which cuts every highlight above
	#     diffuse white — most of what Apple Log holds.
	# A near-zero strength keeps the whole graph in place while adding nothing, so the output must be
	# the input across the full code range.
	local dir="$BATS_TEST_TMPDIR/hal" raw="$BATS_TEST_TMPDIR/ramp.raw"
	"$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0 >/dev/null
	python3 -c '
import struct, sys
w, h = 256, 4
ramp = [i / (w - 1) for i in range(w)] * h
open(sys.argv[1], "wb").write(struct.pack("%df" % (w * h * 3), *(ramp * 3)))
' "$raw"
	run _float_through "$raw" 256 4 "$(halation_prefix "$dir" 4 0.000001 1,1,1)"
	[ "$status" -eq 0 ] || fail "$output"
	local worst
	worst=$(printf '%s\n' "$output" | python3 -c '
import sys
out = [float(l) for l in sys.stdin]
ramp = [i / 255 for i in range(256)] * 4 * 3
assert len(out) == len(ramp), (len(out), len(ramp))
print("%.6f" % max(abs(a - b) for a, b in zip(out, ramp)))
')
	python3 -c "import sys; sys.exit(0 if $worst < 0.001 else 1)" \
		|| fail "the idle stage moved a sample by $worst of full scale (a 10-bit code value is 0.001)"
}

@test "halation glows past an edge, not across a bright field" {
	# EDGE-ONLY is the design: blurring the highlights and adding all of it turned an overcast sky
	# uniformly pink, because a large bright area glows onto itself. What the eye reads as halation
	# is the part that spills past an edge, so the stage adds blur(highlight) - highlight, clamped.
	#
	# Left half bright (Apple Log 0.9, about six times diffuse white), right half dark. Red-only tint,
	# so G and B double as a check that nothing else moved.
	local dir="$BATS_TEST_TMPDIR/hal" raw="$BATS_TEST_TMPDIR/edge.raw"
	"$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0 >/dev/null
	python3 -c '
import struct, sys
w, h = 512, 16
row = [0.9 if x < w // 2 else 0.3 for x in range(w)]
open(sys.argv[1], "wb").write(struct.pack("%df" % (w * h * 3), *(row * h * 3)))
' "$raw"
	# Sigma 16 pixels. The far side is 250 pixels past the edge, which is further than the glow's
	# tail reaches: in log, the dark side is sensitive enough that 60 pixels still read as glow.
	run _float_through "$raw" 512 16 "$(halation_prefix "$dir" 16 1 1,0,0)"
	[ "$status" -eq 0 ] || fail "$output"
	printf '%s\n' "$output" | python3 -c '
import sys
v = [float(l) for l in sys.stdin]
w, h = 512, 16
n = w * h
g, b, r = v[:n], v[n:2 * n], v[2 * n:]
mid = h // 2 * w
def at(plane, x): return plane[mid + x]
problems = []
if at(r, 260) - 0.3 < 0.01:
    problems.append("no red glow just past the edge: %.4f" % at(r, 260))
if abs(at(r, 8) - 0.9) > 0.002 or abs(at(r, 248) - 0.9) > 0.002:
    problems.append("the bright field glowed onto itself: %.4f, %.4f" % (at(r, 8), at(r, 248)))
if abs(at(r, 506) - 0.3) > 0.002:
    problems.append("the glow reached the far side of the frame: %.4f" % at(r, 506))
if max(abs(at(p, x) - (0.9 if x < w // 2 else 0.3)) for p in (g, b) for x in range(w)) > 0.002:
    problems.append("a red-only tint moved green or blue")
sys.exit("; ".join(problems) or None)
' || fail "the glow is not edge-only"
}

@test "a neutral halation is left out of the graph" {
	# Even an idle float round trip moves the picture by a fraction of a code value against the
	# 10-bit path (0.23 code values on average, ADR 0012), so a strength of 0 must remove the stage
	# entirely.
	run "$SCRIPTS/make-halation-luts.py" --check-neutral --strength 0
	[ "$output" = "neutral" ] || fail "strength 0 reported as $output"
	run "$SCRIPTS/make-halation-luts.py" --check-neutral --strength 0.01
	[ "$output" = "active" ] || fail "strength 0.01 reported as $output"

	local work="$BATS_TEST_TMPDIR/neutral-hal" look="$BATS_TEST_TMPDIR/neutral-hal.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	jq '.halation.strength = 0' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" != *"halation:"* ]] || fail "announced a halation that does nothing: $output"
	[ ! -d "$work/dist/.grade-work/halation" ] || fail "generated cubes for a neutral halation"
}

# bats test_tags=slow
@test "an active halation reaches the render and changes the picture" {
	local work="$BATS_TEST_TMPDIR/active-hal" look="$BATS_TEST_TMPDIR/active-hal.json" clip
	mkdir -p "$work/src"
	clip="$work/src/EDGE.mov"
	# An edge, because a flat field is exactly what an edge-only glow leaves alone.
	ffmpeg -y -f lavfi -i "color=c=black:s=72x128:d=0.1:r=24,drawbox=x=0:y=0:w=36:h=128:color=white:t=fill" \
		-frames:v 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$clip" -v error
	jq '.halation.strength = 0.8 | .halation.radius = 0.05' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$clip"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"halation: strength=0.8"* ]] || fail "said nothing about it: $output"
	mv "$work/dist/frames/EDGE_t0s_graded.png" "$work/glowing.png"
	jq '.halation.strength = 0' "$look" > "$look.off"
	LOOK_FILE="$look.off" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$clip"
	[ "$status" -eq 0 ] || fail "$output"
	! cmp -s "$work/glowing.png" "$work/dist/frames/EDGE_t0s_graded.png" \
		|| fail "a strength of 0.8 changed nothing"
}

@test "a halation tint that is not three numbers is refused before it reaches a graph" {
	local work="$BATS_TEST_TMPDIR/bad-tint" look="$BATS_TEST_TMPDIR/bad-tint.json" tint
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	for tint in "1,0.3" "1,0.3,0.05,1" "1,0.3,0.05[x]"; do
		jq --arg t "$tint" '.halation.strength = 0.5 | .halation.tint = $t' \
			"$BATS_TEST_DIRNAME/../look.json" > "$look"
		LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
			run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
		[ "$status" -ne 0 ] || fail "rendered with tint '$tint'"
		[[ "$output" == *"halation.tint"* ]] || fail "tint '$tint' refused without naming it: $output"
		[ ! -d "$work/dist/frames" ] || fail "tint '$tint' got as far as rendering"
	done
}

# --- the print, and how strongly each film cube applies -----------------------

@test "a look at full strength and no print leaves the grade chain as it was" {
	# Absent rather than idle: full strength and no print add no filter, so the chain is the one a
	# look without strengths built.
	local look="$BATS_TEST_DIRNAME/../luts/looks/kodak_portra_400_nc.cube" chain
	chain="$(LOOK_LUT="$look" PRINT_LUT="" LOOK_STRENGTH=1 PRINT_STRENGTH=1 grade_chain t.cube 1 0)"
	[ "$(printf '%s' "$chain" | grep -o 'lut3d' | wc -l | tr -d ' ')" = "1" ] \
		|| fail "expected exactly the look's lut3d: $chain"
	[[ "$chain" != *"mix="* ]] || fail "a full-strength look still blends: $chain"
	chain="$(LOOK_LUT="$look" PRINT_LUT="" LOOK_STRENGTH=0 PRINT_STRENGTH=1 grade_chain t.cube 1 0)"
	[[ "$chain" != *"lut3d"* ]] || fail "a look at strength 0 is still in the graph: $chain"
}

@test "the print follows the look and precedes the tone curve" {
	# A negative, then its print, then the luma-only tone stage — which is what keeps the print's
	# per-channel contrast from turning saturated signage neon.
	local root="$BATS_TEST_DIRNAME/.." chain
	chain="$(LOOK_LUT="$root/luts/looks/kodak_portra_400_nc.cube" \
		PRINT_LUT="$root/luts/print/kodak_2383_constlmap.cube" LOOK_STRENGTH=1 PRINT_STRENGTH=0.5 \
		grade_chain t.cube 1 0)"
	python3 -c '
import sys
c = sys.argv[1]
look, print_, tone = c.find("kodak_portra_400_nc"), c.find("kodak_2383_constlmap"), c.find("lut1d")
sys.exit(None if 0 <= look < print_ < tone else "order is look@%d print@%d tone@%d" % (look, print_, tone))
' "$chain" || fail "the film cubes are out of order: $chain"
}

@test "a film cube's strength blends toward its input by exactly that amount" {
	# A cube that sends everything to 0.8, at strength 0.25, on an input of 0.2: 0.35. Swapping the
	# two weights gives 0.65, which is the mistake this exists to catch.
	local cube="$BATS_TEST_TMPDIR/constant.cube" raw="$BATS_TEST_TMPDIR/grey.raw"
	python3 -c '
import struct, sys
open(sys.argv[1], "w").write("LUT_3D_SIZE 2\n" + "0.8 0.8 0.8\n" * 8)
open(sys.argv[2], "wb").write(struct.pack("48f", *([0.2] * 48)))
' "$cube" "$raw"
	run _float_through "$raw" 4 4 "$(film_lut_stage "$cube" 0.25 t)"
	[ "$status" -eq 0 ] || fail "$output"
	local worst
	worst=$(printf '%s\n' "$output" | python3 -c 'import sys; print("%.6f" % max(abs(float(l) - 0.35) for l in sys.stdin))')
	python3 -c "import sys; sys.exit(0 if $worst < 0.0005 else 1)" \
		|| fail "strength 0.25 did not land a quarter of the way to the cube: off by $worst"
}

@test "a print named in look.json reaches the render and changes the picture" {
	local work="$BATS_TEST_TMPDIR/print" look="$BATS_TEST_TMPDIR/print.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	jq '.print.lut = "kodak_2383_constlmap" | .print.strength = 1' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"print="*"kodak_2383_constlmap.cube@1"* ]] || fail "said nothing about it: $output"
	mv "$work/dist/frames/CLIP_t0s_graded.png" "$work/printed.png"
	jq '.print.lut = "none"' "$look" > "$look.none"
	LOOK_FILE="$look.none" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	! cmp -s "$work/printed.png" "$work/dist/frames/CLIP_t0s_graded.png" \
		|| fail "a print at full strength changed nothing"
}

@test "a print that is not on disk is refused, naming where prints live" {
	local work="$BATS_TEST_TMPDIR/no-print"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	PRINT=no_such_stock FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -ne 0 ] || fail "rendered with a print that does not exist"
	[[ "$output" == *"luts/print/"* ]] || fail "refused without saying where prints live: $output"
	[[ "$output" == *"kodak_2383_constlmap"* ]] || fail "did not list the prints that do exist: $output"
}

# --- grain weighted by brightness ---------------------------------------------

# Grain sd per ninth of a horizontal ramp, darkest first, after merging a plate through the given
# weights. The ramp is `geq`, not `gradients`: the latter seeds itself randomly, and two renders of
# it disagreed by a whole band.
_grain_bands() {  # _grain_bands <shadows> <highlights>   -> nine numbers, then the chroma verdict
	local dir="$BATS_TEST_TMPDIR/grain" w=1080 h=320 src
	mkdir -p "$dir"
	src="nullsrc=s=${w}x${h}:d=0.1:r=24,geq=lum='16+219*X/W':cb=128:cr=128,format=yuv420p,${DELIVERY_SETPARAMS}"
	ffmpeg -v error -y -f lavfi -i "$src" -frames:v 1 -f rawvideo -pix_fmt yuv420p "$dir/clean.yuv"
	ffmpeg -v error -y -f lavfi -i "$src" -f lavfi -i "$(grain_plate "$w" "$h" 24)" \
		-filter_complex "[0:v]null[b];[1:v]$(delivery_grain_branch "$w" "$h" 8)[g];$(delivery_grain_merge b g o "$1" "$2")" \
		-map "[o]" -frames:v 1 -f rawvideo -pix_fmt yuv420p "$dir/grained.yuv"
	python3 - "$dir/clean.yuv" "$dir/grained.yuv" "$w" "$h" <<'PY'
import math, sys
a, b = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
w, h = int(sys.argv[3]), int(sys.argv[4])
bands = []
for x0 in range(0, w, w // 9):
    d = [b[y * w + x] - a[y * w + x] for y in range(0, h, 2) for x in range(x0, x0 + w // 9, 2)]
    m = sum(d) / len(d)
    bands.append("%.2f" % math.sqrt(sum((v - m) ** 2 for v in d) / len(d)))
print(" ".join(bands[:9]))
print("chroma-untouched" if a[w * h:] == b[w * h:] else "chroma-moved")
PY
}

@test "weighted grain recedes into shadow and highlight, and stays luma-only" {
	# Print grain is most visible in the midtones. Measured at 0.35 and 0.5: sd 1.2 in the darkest
	# ninth, 3.2 at the midtones, 1.8 in the brightest, against a flat 3.2 unweighted.
	# Judged against the same plate merged flat, so the bounds are ratios rather than one ramp's sd.
	run _grain_bands 1 1
	[ "$status" -eq 0 ] || fail "$output"
	local flat bands verdict
	flat="$(printf '%s\n' "$output" | head -1)"
	run _grain_bands 0.35 0.5
	[ "$status" -eq 0 ] || fail "$output"
	bands="$(printf '%s\n' "$output" | head -1)"
	verdict="$(printf '%s\n' "$output" | tail -1)"
	python3 -c '
import sys
f = [float(v) for v in sys.argv[1].split()]
b = [float(v) for v in sys.argv[2].split()]
problems = []
if b[0] > 0.5 * f[0]: problems.append("deep shadow keeps %.2f of a flat %.2f" % (b[0], f[0]))
if b[8] > 0.7 * f[8]: problems.append("the highlights keep %.2f of a flat %.2f" % (b[8], f[8]))
if b[4] < 0.9 * f[4]: problems.append("the midtones lost grain: %.2f of a flat %.2f" % (b[4], f[4]))
sys.exit("; ".join(problems) or None)
' "$flat" "$bands" || fail "grain is not weighted by brightness: flat $flat, weighted $bands"
	# The plate is grey so grainmerge leaves chroma alone, and the hqdn3d pass depends on that.
	[ "$verdict" = "chroma-untouched" ] || fail "weighted grain moved the chroma planes"
}

@test "flat grain weights leave the mask out of the graph" {
	# Absent, not idle: flat grain is the plain blend, with no mask built for nothing.
	[ "$(delivery_grain_merge b g o 1 1)" = "[b][g]${DELIVERY_BLEND}[o]" ] \
		|| fail "weights of 1 still built a mask: $(delivery_grain_merge b g o 1 1)"
	[ "$(delivery_grain_merge b g o 1.0 1.00)" = "[b][g]${DELIVERY_BLEND}[o]" ] \
		|| fail "1.0 was read as a different number from 1"
	[[ "$(delivery_grain_merge b g o 0.9 1)" == *maskedmerge* ]] || fail "a weight of 0.9 built no mask"
}

@test "a grain weight outside 0 to 1 is refused before anything renders" {
	local work="$BATS_TEST_TMPDIR/bad-grain" look="$BATS_TEST_TMPDIR/bad-grain.json" v
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	for v in 1.5 -0.1 "0.5:x"; do
		jq --arg v "$v" '.grain.shadows = $v' "$BATS_TEST_DIRNAME/../look.json" > "$look"
		LOOK_FILE="$look" FRAME=0 FRAME_HEIGHT=128 MATCH=0 GRADE_WORK_DIR="$work" \
			run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
		[ "$status" -ne 0 ] || fail "rendered with grain.shadows '$v'"
		[[ "$output" == *"grain.shadows"* ]] || fail "'$v' refused without naming it: $output"
		[ ! -d "$work/dist/frames" ] || fail "'$v' got as far as rendering"
	done
}

@test "a weighted grain render finishes rather than following the infinite plate" {
	# The plates are endless lavfi sources and `maskedmerge` has no `shortest` option; the render
	# has to end because its mask comes from the image. A proof that never finished would be the
	# DELIVERY_BLEND incident again, one filter earlier.
	local work="$BATS_TEST_TMPDIR/grain-proof" look="$BATS_TEST_TMPDIR/grain-proof.json"
	mkdir -p "$work/src"
	cp "$FIXTURES/portrait_tagged.mov" "$work/src/CLIP.mov"
	jq '.grain.shadows = 0.35 | .grain.highlights = 0.5' "$BATS_TEST_DIRNAME/../look.json" > "$look"
	LOOK_FILE="$look" PROOF=0.1 STAB=0 MATCH=0 GRADE_WORK_DIR="$work" \
		run "$SCRIPTS/grade.sh" "$work/src/CLIP.mov"
	[ "$status" -eq 0 ] || fail "$output"
	local out
	out=$(find "$work/dist/proofs" -name '*.mp4' | head -1)
	[ -s "$out" ] || fail "no proof was written: $output"
}

# bats test_tags=serial
@test "the staged path refuses a look it cannot apply, rather than rendering without part of it" {
	# A baseline has already been converted, so a stage that runs before the conversion has nowhere
	# to go. For as long as the correction existed this path rendered masters without it, and they
	# looked finished.
	local work="$BATS_TEST_TMPDIR/staged-pre" base look="$BATS_TEST_TMPDIR/staged-pre.json" key
	base="$work/dist/01-baseline/CCC_baseline.mov"
	mkdir -p "$(dirname "$base")"
	ffmpeg -y -f lavfi -i "testsrc2=s=72x128:d=0.1:r=24" \
		-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$base" -v error
	for key in '.correct.exposure = 0.5' '.halation.strength = 0.4'; do
		jq "$key" "$BATS_TEST_DIRNAME/../look.json" > "$look"
		LOOK_FILE="$look" GRADE_WORK_DIR="$work" run "$SCRIPTS/02-grade.sh" CCC
		[ "$status" -ne 0 ] || fail "rendered a master with '$key' left out"
		[[ "$output" == *"runs before Apple's conversion"* ]] || fail "'$key' refused without saying why: $output"
		[[ "$output" == *"GRADE_CODE=REFUSE_STAGED_PRE_CONVERSION"* ]] || fail "'$key' refused without its code"
		[ ! -e "$work/dist/02-graded/CCC_graded.mov" ] || fail "'$key' got as far as encoding"
	done
}

@test "the halation cubes are regenerated by content, and only the one a change affects" {
	local dir="$BATS_TEST_TMPDIR/hal-fresh"
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0
	[ "$status" -eq 0 ]
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold 1.0
	[[ "$output" == *"already current"* ]] || fail "rewrote cubes that already matched: $output"
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold 2.0
	[ "$output" = "wrote halation-threshold.cube" ] || fail "a threshold change rewrote: $output"
	grep -q 'threshold=2' "$dir/halation-threshold.cube" || fail "the cube does not record its threshold"
	run "$SCRIPTS/make-halation-luts.py" "$dir" --threshold -1
	[ "$status" -ne 0 ] || fail "accepted a negative threshold"
	[[ "$output" == *"--threshold outside"* ]] || fail "not refused at the threshold: $output"
	grep -q 'threshold=2' "$dir/halation-threshold.cube" || fail "a refused threshold still rewrote the cube"
}

@test "the recorded event stream still matches what the engine emits" {
	# The app parses these events, and a parser is only as good as the shape it was written
	# against. This pins the contract by CONTENT: field names, order and types, with the work dir
	# and the volume's free space tokenised because neither is reproducible.
	#
	# It is also the fixture the app's own tests read, so they need no ffmpeg and no footage.
	local fixture="$BATS_TEST_DIRNAME/fixtures/events.jsonl" now
	[ -f "$fixture" ] || fail "no recorded stream at $fixture"
	# SKIP ONLY ON 3, which is the generator's documented "no ffmpeg". A bare `|| skip` swallowed
	# every other failure as a pass, and it hid a real one: the generator's own clips were 1:2, so
	# once a deliverable became an aspect its two-clip run was refused, the generator exited 1, and
	# this test reported a skip instead of the broken contract it exists to catch. A missing tool is
	# a skip; a generator that fails is a failure.
	local rc=0
	now="$("$BATS_TEST_DIRNAME/make-event-fixture.sh" --check)" || rc=$?
	[ "$rc" -ne 3 ] || skip "ffmpeg not installed"
	[ "$rc" -eq 0 ] || fail "the fixture generator failed (exit $rc): $now"
	if [ "$now" != "$(cat "$fixture")" ]; then
		printf 'recorded:\n%s\nnow:\n%s\n' "$(cat "$fixture")" "$now"
		fail "the event stream changed. If that was intended, re-run tests/make-event-fixture.sh and say in the commit what moved."
	fi
	# And it is a stream, not a blob: one object per line, each parseable on its own.
	printf '%s\n' "$now" | _json_lines || fail "the recorded stream is not one object per line"
	[[ "$now" == *'"event":"run_done"'* ]] \
		|| fail "the stream has no run_done, so a consumer cannot tell it ended"
}

# --- the app's toolchain ------------------------------------------------------
# Xcode 15.2 is the newest release for this machine's macOS, which caps Swift at 5.9 and the SDK at
# 14.2. The risk of working across two machines is one-directional: raising the tools version or
# reaching for a newer API on the newer Mac leaves the always-available one unable to build at all.
# Prose cannot hold that line, so a test does.

@test "the Swift package still pins the toolchain this machine can build" {
	local pkg="$BATS_TEST_DIRNAME/../app/Package.swift"
	[ -f "$pkg" ] || skip "no Swift package yet"
	grep -q '^// swift-tools-version:5.9$' "$pkg" \
		|| fail "the tools version moved off 5.9: $(head -1 "$pkg")"
	grep -q 'platforms: \[.macOS(.v13)\]' "$pkg" \
		|| fail "the deployment target moved off macOS 13"
	# @Observable is macOS 14 and the obvious thing to reach for; ObservableObject is the one that
	# builds here. Caught by grep rather than by a build failure on the wrong machine.
	#
	# The pattern needs its boundary: `@Observable` is a PREFIX of `@ObservedObject`, so the
	# obvious grep flagged the correct spelling as the forbidden one and this test failed on code
	# that builds. A guard that cannot tell the two apart is worse than none, because the fix it
	# demands is wrong.
	# And it has to ignore COMMENTS, or the sentence explaining the rule trips the rule. Matching
	# only where no slash precedes it does that: `/// ... @Observable` is excluded, an actual
	# attribute at the start of a line is not.
	! grep -rnE '^[^/]*@Observable([^A-Za-z]|$)' "$BATS_TEST_DIRNAME/../app/Sources" \
		|| fail "@Observable needs macOS 14; use ObservableObject"
}

# bats test_tags=slow,serial
@test "the app bundle script produces something launchable" {
	command -v swift >/dev/null || skip "no swift toolchain"
	local app="$BATS_TEST_DIRNAME/../dist/LogGrade.app"
	# --debug on purpose. This test is about the bundle's SHAPE — an executable, an Info.plist, the
	# engine vendored beside it — none of which optimisation affects, and a release build of the
	# package costs twenty seconds of every suite run to prove nothing this test asserts. The
	# release build IS exercised, by the next test, which is the one that matters because it is the
	# configuration the app actually ships in.
	run "$BATS_TEST_DIRNAME/../app/make-app.sh" --debug
	[ "$status" -eq 0 ] || fail "$output"
	[ -x "$app/Contents/MacOS/LogGrade" ] || fail "no executable in the bundle"
	[ -f "$app/Contents/Info.plist" ] || fail "no Info.plist, so macOS treats it as a stray binary"
	# The engine travels with it: a launched app inherits no useful PATH and should not break
	# because a checkout moved.
	[ -x "$app/Contents/Resources/engine/scripts/grade.sh" ] || fail "the engine was not vendored"
	[ -f "$app/Contents/Resources/engine/look.json" ] || fail "look.json was not vendored"
	# Drawn from the shipped curve by make-icon.swift. Without it macOS gives the app the generic
	# document icon, which is how you tell at a glance that a build went wrong.
	[ -f "$app/Contents/Resources/AppIcon.icns" ] || fail "the icon was not drawn into the bundle"
}

# bats test_tags=slow,serial
@test "the default build is the optimised one, because the live preview needs it" {
	command -v swift >/dev/null || skip "no swift toolchain"
	# THE CONFIGURATION MATTERS MORE THAN IT LOOKS. The live preview grades a whole frame per
	# control change, and unoptimised that is 1.5 seconds against 12.7ms — a build that does not
	# feel slow so much as broken. So the default has to stay release, and passing --release must
	# not be what gets you there. This is the only test that compiles the app the way it ships.
	run "$BATS_TEST_DIRNAME/../app/make-app.sh"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"(release)"* ]] || fail "make-app.sh did not default to release: $output"
	[ -x "$BATS_TEST_DIRNAME/../app/.build/release/LogGrade" ] || fail "no optimised binary"
}

@test "a measured exposure can be handed back instead of measured again" {
	# The probe reads a number that does not change when a look does, so an interface adjusting a
	# curve re-measures the same value on every render — about a second of a four-second preview.
	# What matters is that the shortcut is not a different grade.
	#
	# A SYNTHETIC CLIP, and a handed value the clip does not measure. This used real footage and
	# handed back exactly the value it had just measured, so "the handed value was used" was true
	# whether the handback worked or the probe simply ran again. It also cost 8 seconds and skipped
	# without footage. Nothing here depends on the camera's file structure.
	local src="$FIXTURES/probe_mid.mov" a="$BATS_TEST_TMPDIR/measured" b="$BATS_TEST_TMPDIR/handed"
	mkdir -p "$a" "$b"
	GRADE_WORK_DIR="$a" DRY=1 STAB=0 run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "$output"
	local measured measured_line
	measured_line=$(printf '%s\n' "$output" | grep 'YAVG=' | head -1) || true
	measured=$(printf '%s\n' "$measured_line" | sed -n 's/.*YAVG=\([0-9.]*\).*/\1/p')
	[ -n "$measured" ] || fail "the probe reported nothing: $output"

	# The same number handed back is the same solve.
	YAVG_IN="$measured" GRADE_WORK_DIR="$b" DRY=1 STAB=0 run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"$measured_line"* ]] || fail "handing back $measured changed the grade: $output"

	# A number the clip does not measure is the one that shows the probe was skipped.
	local other=$(( ${measured%.*} + 150 ))
	YAVG_IN="$other" GRADE_WORK_DIR="$b" DRY=1 STAB=0 run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -eq 0 ] || fail "$output"
	[[ "$output" == *"YAVG=${other} "* ]] || fail "measured again instead of using $other: $output"
	[[ "$output" == *"(matched)"* ]] || fail "the solve did not run: $output"

	# And a value that is not a number is refused rather than spliced into the solve.
	YAVG_IN="600,metadata=print" GRADE_WORK_DIR="$b" DRY=1 STAB=0 run "$SCRIPTS/grade.sh" "$src"
	[ "$status" -ne 0 ] || fail "accepted a non-numeric exposure"
	[[ "$output" == *"YAVG_IN must be numeric"* ]] || fail "refused without saying why: $output"
}

# tests/render-golden.sh holds the default image to this repo's own recorded render (ADR 0014). Its
# render cannot run here in seconds, and check.sh runs it for real; these cover the two ways it can
# be relaxed without anyone seeing, and assert the work was not attempted, since a render that
# fails for any other reason would also exit non-zero.

@test "the render golden refuses to move without a reason" {
	local golden="$BATS_TEST_TMPDIR/render-golden.json"
	printf '{"stream_md5":"recorded"}\n' > "$golden"
	GOLDEN="$golden" run "$BATS_TEST_DIRNAME/render-golden.sh" --regenerate
	[ "$status" -eq 2 ] || fail "expected a usage refusal, got $status: $output"
	[[ "$output" == *"--regenerate needs a reason"* ]] || fail "refused without saying why: $output"
	[[ "$output" != *"clip:"* ]] || fail "rendered before refusing: $output"
	[ "$(cat "$golden")" = '{"stream_md5":"recorded"}' ] || fail "the golden was rewritten"
}

@test "a render golden from another ffmpeg build is skipped by name, not compared" {
	[ -f "$BATS_TEST_DIRNAME/../luts/apple/AppleLogToRec709-v1.0.cube" ] || skip "no Apple cube"
	local golden="$BATS_TEST_TMPDIR/render-golden.json"
	printf '{"clip":{"name":"IMG_0607.mov","bytes":1},"proof_secs":0.1,"ffmpeg":"ffmpeg version 0-other","arch":"%s","stream_md5":"x","inputs":{}}\n' \
		"$(uname -m)" > "$golden"
	GOLDEN="$golden" run "$BATS_TEST_DIRNAME/render-golden.sh"
	[ "$status" -eq 3 ] || fail "expected a skip, got $status: $output"
	[[ "$output" == *"recorded with 'ffmpeg version 0-other'"* ]] || fail "skipped without naming the build: $output"
	[[ "$output" != *"clip:"* ]] || fail "rendered against a golden from another build: $output"
}
