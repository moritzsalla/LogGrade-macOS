#!/bin/bash
# Assembles LogGrade.app around the binary SwiftPM builds.
#
# WHY BY HAND. A SwiftUI executable without a bundle has no Info.plist, so macOS gives it no dock
# icon, no menu bar and no way to be a Finder drop target — and a window opened from one arrives
# behind everything. The bundle is four files and a directory layout, which is cheaper than
# maintaining an Xcode project for a personal tool, and it keeps the build a script rather than a
# GUI action.
#
# WHAT GOES INSIDE. The engine too: scripts/, luts/ and look.json are copied in, because the app
# should not stop working when a checkout moves. A debug build points at the working copy instead,
# so engine scripts stay editable without a rebuild — see LOGGRADE_ENGINE.
#
# RELEASE BY DEFAULT, and this is not a preference. The live preview grades a whole frame per
# slider tick, and Swift's bounds and overflow checks make that 1.5 SECONDS in a debug build
# against 12.7ms in a release one. A debug build does not feel slow; it feels broken. Pass --debug
# when you are debugging the app itself and can live with that.
#
# UNIVERSAL, because one bundle built here has to run natively on an Apple silicon Mac too. That
# includes the tools: an Intel-only ffmpeg would run there under Rosetta, and on a fresh Mac it
# makes macOS ask to install Rosetta before the app can render at all. So every executable in the
# bundle is merged from two slices, and one that is not universal stops the build.
#
# THE TOOLS ARE PINNED, not taken from PATH, so what goes into a bundle is decided by the commit.
# ./app/fetch-tools.sh downloads them, and its header says where each comes from and why that
# source; app/tools.sha256 holds their hashes.
#
# Usage:  ./app/make-app.sh [--debug]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=release
[ "${1:-}" != "--debug" ] || CONFIG=debug

command -v swift >/dev/null || { echo "swift not installed"; exit 1; }

# Checked before the build, which is the slow part, and by hash rather than by presence: a file of
# the right name from somewhere else would put a different renderer in the bundle without a word.
TOOLS="${LOGGRADE_TOOLS:-$HOME/.local/share/loggrade-tools}"
if ! (cd "$TOOLS" 2>/dev/null && shasum -a 256 -c --quiet "$ROOT/app/tools.sha256" >&2); then
	echo "ERROR: the pinned ffmpeg, ffprobe and jq are not in $TOOLS." >&2
	echo "  Run ./app/fetch-tools.sh, which downloads and verifies them." >&2
	exit 1
fi

# More than one --arch sends SwiftPM through Xcode's build system, which writes the product under
# .build/apple/Products/<Config>/ and not .build/<config>/. The old path may still hold a stale
# host-only binary from an earlier build, so nothing may read it.
swift build --package-path "$ROOT/app" -c "$CONFIG" --arch arm64 --arch x86_64
PRODUCTS="$ROOT/app/.build/apple/Products"
BIN="$PRODUCTS/Release/LogGrade"
[ "$CONFIG" = release ] || BIN="$PRODUCTS/Debug/LogGrade"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

APP="$ROOT/dist/LogGrade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/LogGrade"

# The icon is DRAWN from the shipped tone curve, not stored, so a re-grade changes it. A second
# here rather than a PNG in the tree that nobody remembers to redraw. See app/make-icon.swift.
# From $ROOT: make-icon.swift reads look.json and scripts/ relative to the working directory, so
# a build started from anywhere else would silently fall back to the generic icon.
if (cd "$ROOT" && swift app/make-icon.swift >/dev/null); then
	cp "$ROOT/dist/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "WARNING: could not draw the icon; the app will use the generic one" >&2
fi

# The engine, vendored, and the tools beside it: EngineRun puts the engine's directory first on the
# child's PATH, because a launched app's own PATH knows nothing of ~/.local/bin or Homebrew.
ENGINE="$APP/Contents/Resources/engine"
# -L: a symlinked cube (a worktree links Apple's, which cannot be committed) would be copied as a
# link to a path outside the bundle. That fails `codesign --strict` here and is a dangling link on
# the other Mac.
cp -RL "$ROOT/scripts" "$ROOT/luts" "$ROOT/look.json" "$ENGINE/"
for tool in ffmpeg ffprobe jq; do
	lipo -create "$TOOLS/x86_64/$tool" "$TOOLS/arm64/$tool" -output "$ENGINE/$tool"
done

# A single-architecture executable is an error, not a warning. Nothing on the Intel Mac would ever
# notice one, and on the Apple Mac it means Rosetta, or no launch at all.
for exe in "$APP/Contents/MacOS/LogGrade" "$ENGINE/ffmpeg" "$ENGINE/ffprobe" "$ENGINE/jq"; do
	if ! lipo "$exe" -verify_arch x86_64 arm64; then
		echo "ERROR: $exe is not universal: $(lipo -archs "$exe")" >&2
		exit 1
	fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>LogGrade</string>
	<key>CFBundleIdentifier</key><string>local.loggrade</string>
	<key>CFBundleName</key><string>LogGrade</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>QuickTime Movie</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array><string>com.apple.quicktime-movie</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# SIGNED, AND A FAILURE STOPS THE BUILD. Apple silicon kills arm64 code with no valid signature,
# so a bundle that only warned here would build fine and never launch there. Ad-hoc is enough for
# a bundle that is never distributed and needs no developer account.
# The tools first, then the bundle: `codesign "$APP"` does not reach executables under Resources/,
# and the merged tools arrive unsigned: evermeet's and jq's x86_64 binaries carry no signature,
# and `codesign -v` on a lipo-merged ffprobe reports the whole file unsigned.
for tool in ffmpeg ffprobe jq; do
	codesign --force --sign - "$ENGINE/$tool" || { echo "ERROR: could not sign $tool" >&2; exit 1; }
done
codesign --force --sign - "$APP" || { echo "ERROR: could not sign the bundle" >&2; exit 1; }
codesign --verify --deep --strict "$APP" \
	|| { echo "ERROR: the bundle's signature does not verify" >&2; exit 1; }

# TELL THE SYSTEM THE BUNDLE CHANGED, or Finder keeps showing the generic application icon.
# macOS caches an app's icon against its PATH, and this script deletes and recreates the bundle at
# the same path on every build — so the cache is never invalidated and the app looks like it has
# no icon at all, however correct the .icns inside it is. Touching the bundle and re-registering it
# is what makes Finder look again.
touch "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1
echo "built $APP ($CONFIG)"
