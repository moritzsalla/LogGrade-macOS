#!/bin/bash
# Mutation-test a guard: break it on purpose and see whether its covering test notices.
#
#   tests/mutate.sh [--nth N] <file> <old> <new> -- <test command...>
#
#   tests/mutate.sh scripts/lib.sh 'exit 1' 'true' -- bats -f 'refuses a missing key' tests/lib.bats
#   tests/mutate.sh app/Sources/GradeKit/Project.swift 'return y - y % 2' 'return y' \
#   	-- swift test --package-path app --filter CropGeometryTests/testTheCentreBoxIsWhereTheEngineCentres
#
# <old> is a LITERAL, never a regex: sd and perl s/// expand `$NAME` in a replacement, and these
# files are full of shell variables. Use $'...' for a multi-line literal. It must occur exactly
# once, or pass --nth to pick one; a mutation that silently matched nothing reads as a survivor
# of a mutation that was never made.
#
# The test runs first on the unmutated file. A test that already fails would report every mutation
# KILLED.
#
# Exit: 0 KILLED (the test failed on the mutant — the guard is covered), 1 SURVIVED, 2 anything
# that makes the verdict meaningless (bad usage, no single match, baseline red, restore failed).
#
# The file is restored from a byte copy, not `git checkout`: the guard under test is usually
# uncommitted work.
set -euo pipefail

nth=""
if [ "${1:-}" = "--nth" ]; then
	nth="${2:-}"
	shift 2 || true
	case "$nth" in ''|*[!0-9]*|0) echo "mutate: --nth takes a positive number" >&2; exit 2;; esac
fi
if [ "$#" -lt 5 ] || [ "$4" != "--" ]; then
	sed -n 4p "$0" | sed 's/^# *//' >&2
	exit 2
fi
file="$1" old="$2" new="$3"
shift 4
[ -f "$file" ] || { echo "mutate: no such file: $file" >&2; exit 2; }
[ -n "$old" ] || { echo "mutate: <old> is empty" >&2; exit 2; }
[ "$old" != "$new" ] || { echo "mutate: <old> and <new> are the same" >&2; exit 2; }

echo "== baseline: $*"
if ! "$@"; then
	echo "mutate: the test fails on the UNMUTATED file; no verdict is possible" >&2
	exit 2
fi

sum_before="$(shasum -a 256 < "$file")"
backup="$(mktemp -t mutate)"
cp -p "$file" "$backup"

restored=0
restore() {
	[ "$restored" = "1" ] && return 0
	cp -p "$backup" "$file"
	if [ "$(shasum -a 256 < "$file")" != "$sum_before" ]; then
		echo "mutate: RESTORE FAILED — $file differs from the original, kept at $backup" >&2
		return 1
	fi
	rm -f "$backup"
	restored=1
}
# A signal restores too, then exits with its conventional code, so the caller sees an interrupt
# rather than a verdict.
trap 'restore || exit 2' EXIT
trap 'restore; trap - EXIT; exit 130' INT
trap 'restore; trap - EXIT; exit 143' TERM
trap 'restore; trap - EXIT; exit 129' HUP

# perl with index/substr, and the strings through the environment, so nothing in them is ever
# interpreted. Prints the match count; replaces only when the choice is unambiguous.
count="$(MUT_OLD="$old" MUT_NEW="$new" MUT_NTH="$nth" perl -0777 -e '
	my ($old, $new, $nth) = @ENV{qw(MUT_OLD MUT_NEW MUT_NTH)};
	my $path = shift;
	open(my $in, "<", $path) or die "$path: $!";
	my $src = do { local $/; <$in> }; close $in;
	my @at; my $i = 0;
	while (($i = index($src, $old, $i)) >= 0) { push @at, $i; $i += length $old; }
	print scalar @at;
	my $pick = $nth ne "" ? $nth : (@at == 1 ? 1 : 0);
	exit 0 unless $pick >= 1 && $pick <= @at;
	substr($src, $at[$pick - 1], length $old) = $new;
	open(my $out, "+<", $path) or die "$path: $!";
	truncate($out, 0); print $out $src; close $out;
' "$file")"

if [ -z "$nth" ] && [ "$count" != "1" ]; then
	echo "mutate: <old> occurs $count times in $file; need exactly 1, or --nth" >&2
	exit 2
fi
if [ -n "$nth" ] && [ "$nth" -gt "$count" ]; then
	echo "mutate: --nth $nth, but <old> occurs $count times in $file" >&2
	exit 2
fi
if [ "$(shasum -a 256 < "$file")" = "$sum_before" ]; then
	echo "mutate: $file did not change; the mutation was not applied" >&2
	exit 2
fi
echo "== mutated $file:"
diff "$backup" "$file" || true

echo "== mutant: $*"
set +e; "$@"; rc=$?; set -e

restore || exit 2
trap - EXIT INT TERM HUP
echo "== restored $file (sha256 matches)"
if [ "$rc" = "0" ]; then
	echo "SURVIVED: the test passed with the guard broken"
	exit 1
fi
echo "KILLED: the test failed (exit $rc)"
