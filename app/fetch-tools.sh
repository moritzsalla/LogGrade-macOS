#!/bin/bash
# Downloads the ffmpeg, ffprobe and jq that make-app.sh merges into a universal bundle, one binary
# per architecture, and installs each only once it matches app/tools.sha256.
#
# WHY A SCRIPT. The first universal build read hand-downloaded files from
# ~/.local/share/loggrade-tools, described by a note that lived beside them and nowhere else. A
# clone could not rebuild the app, and nothing said whether the files on disk were the ones
# described. With the URLs pinned here and the hashes in the repo, the commit decides the bundle.
#
# THE HASHES ARE OF THE BINARIES, not the archives. OSXExperts publishes the hash of the extracted
# executable, and the x86_64 ffmpeg has to be byte-identical to the ~/.local/bin/ffmpeg every
# render and golden on the Intel Mac was made with. A zip's hash says neither.
#
# WHERE EACH COMES FROM, AND WHY
#
# x86_64 ffmpeg, ffprobe: 9.0.1-tessus, https://evermeet.cx/ffmpeg/, GPL v3+ (configured with
#   --enable-gpl --enable-version3). The build already in ~/.local/bin, same sha256, so the image
#   on the machine where it is judged does not move. evermeet publishes no Apple silicon build.
#
# arm64 ffmpeg, ffprobe: 9.0, https://www.osxexperts.net/, GPL v2+ (--enable-gpl only). The only
#   static arm64 build found with libvidstab, which stage 0's vidstabdetect and vidstabtransform
#   need. martin-riedl.de's arm64 9.0.1 lacks it; Homebrew's links libraries under /opt/homebrew
#   and breaks on a Mac without them. Both hashes matched the ones that page published on
#   2026-09-15. Its URLs name no point release, so a newer build would likely replace the file and
#   fail the pin — intended: read what changed before accepting a new hash.
#   It cannot run on an Intel Mac, so it was checked with `strings`: the configure line has
#   libvidstab, libzimg, libx264; every filter, encoder and muxer name found in scripts/,
#   app/Sources and tests/*.sh (zscale, lut3d, lut1d, curves, blend, gblur, mergeplanes, setparams,
#   prores_ks, ...) is present. The check can fail: rubberband, libxvid and zmq, which only the
#   evermeet build has, are absent. otool -L lists only system libraries. A string is not a working
#   filter; only a render on the Apple Mac proves the slice (docs/UNIVERSAL_APP_PLAN.md).
#
# jq: 1.8.2, https://github.com/jqlang/jq/releases, MIT. The project's own binaries. Both carry
#   minos 14.0; the x86_64 one runs on macOS 13.7.8 regardless, the arm64 one is unverified on 13.
#
# THE TWO ffmpeg BUILDS ARE DIFFERENT RENDERERS: 9.0 against 9.0.1, other compilers and flags, NEON
# against x86 SIMD. A render on the Apple Mac may not be byte-identical to one here.
#
# Usage:  ./app/fetch-tools.sh     (LOGGRADE_TOOLS overrides the install directory)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${LOGGRADE_TOOLS:-$HOME/.local/share/loggrade-tools}"
SUMS="$ROOT/app/tools.sha256"

# arch/name, then the URL, then the member to extract — empty for a bare binary.
PINNED="
x86_64/ffmpeg	https://evermeet.cx/ffmpeg/ffmpeg-9.0.1.zip	ffmpeg
x86_64/ffprobe	https://evermeet.cx/ffmpeg/ffprobe-9.0.1.zip	ffprobe
x86_64/jq	https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-amd64
arm64/ffmpeg	https://www.osxexperts.net/ffmpeg9arm.zip	ffmpeg
arm64/ffprobe	https://www.osxexperts.net/ffprobe9arm.zip	ffprobe
arm64/jq	https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-arm64
"

expected() { awk -v k="$1" '$2 == k { print $1 }' "$SUMS"; }
actual() { shasum -a 256 "$1" | awk '{ print $1 }'; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "$PINNED" | while IFS="	" read -r tool url member; do
	[ -n "$tool" ] || continue
	want="$(expected "$tool")"
	[ -n "$want" ] || { echo "ERROR: $tool has no hash in $SUMS" >&2; exit 1; }
	dest="$TOOLS/$tool"
	if [ -f "$dest" ] && [ "$(actual "$dest")" = "$want" ]; then
		echo "ok       $tool"
		continue
	fi
	echo "fetching $tool  <- $url"
	download="$STAGE/download"
	curl -fsSL --retry 3 -o "$download" "$url"
	if [ -n "$member" ]; then
		# Named member only: the OSXExperts archives also carry __MACOSX/._ffmpeg.
		rm -rf "$STAGE/x"
		unzip -q -o "$download" "$member" -d "$STAGE/x"
		candidate="$STAGE/x/$member"
	else
		candidate="$download"
	fi
	got="$(actual "$candidate")"
	if [ "$got" != "$want" ]; then
		echo "ERROR: $tool from $url hashes to $got, pinned $want. Not installed." >&2
		exit 1
	fi
	mkdir -p "$(dirname "$dest")"
	chmod 755 "$candidate"
	mv -f "$candidate" "$dest"
	echo "ok       $tool"
done

(cd "$TOOLS" && shasum -a 256 -c --quiet "$SUMS")
echo "tools verified in $TOOLS"
