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
# UNIVERSAL BINARY. Build runs on Intel, producing both x86_64 and arm64 slices for copying to
# Apple silicon. Requires arm64 tools in ~/.local/share/loggrade-tools/ (see docs/UNIVERSAL_APP_PLAN.md).
# jq exists for both; ffmpeg and ffprobe are x86_64 only — no trustworthy static arm64 build
# exists from the original source (evermeet.cx). This limits ffmpeg to Rosetta on Apple silicon.
#
# Usage:  ./app/make-app.sh [--debug]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=release
[ "${1:-}" != "--debug" ] || CONFIG=debug

command -v swift >/dev/null || { echo "swift not installed"; exit 1; }

# Build universal for both x86_64 and arm64. SwiftPM routes multiple --arch to Xcode and writes
# to .build/apple/Products/{Config}/ instead of .build/{Config}/.
swift build --package-path "$ROOT/app" -c "$CONFIG" --arch arm64 --arch x86_64
if [ "$CONFIG" = release ]; then
	BIN="$ROOT/app/.build/apple/Products/Release/LogGrade"
else
	BIN="$ROOT/app/.build/apple/Products/Debug/LogGrade"
fi
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

# The engine, vendored. Tools come from ~/.local/share/loggrade-tools/ for reproducibility.
# For universal builds, jq gets both slices via lipo; ffmpeg/ffprobe are x86_64 only.
cp -R "$ROOT/scripts" "$ROOT/luts" "$ROOT/look.json" "$APP/Contents/Resources/engine/"

TOOLS_DIR="$HOME/.local/share/loggrade-tools"

# jq: merge x86_64 and arm64 slices into a universal binary
if [ -f "$TOOLS_DIR/x86_64/jq" ] && [ -f "$TOOLS_DIR/arm64/jq" ]; then
	lipo -create "$TOOLS_DIR/x86_64/jq" "$TOOLS_DIR/arm64/jq" \
		-output "$APP/Contents/Resources/engine/jq"
	chmod +x "$APP/Contents/Resources/engine/jq"
elif [ -f "$TOOLS_DIR/x86_64/jq" ]; then
	cp "$TOOLS_DIR/x86_64/jq" "$APP/Contents/Resources/engine/jq"
	echo "WARNING: arm64 jq not found; bundle contains x86_64 only" >&2
else
	echo "ERROR: jq not found in $TOOLS_DIR/x86_64/" >&2
	exit 1
fi

# ffmpeg and ffprobe: x86_64 only (no trustworthy arm64 static build available)
for tool in ffmpeg ffprobe; do
	src="$TOOLS_DIR/x86_64/$tool"
	if [ -f "$src" ]; then
		cp "$src" "$APP/Contents/Resources/engine/"
	else
		echo "ERROR: $tool not found in $TOOLS_DIR/x86_64/" >&2
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

# Sign each executable before signing the bundle. Apple silicon kills unsigned arm64 code.
# lipo invalidates signatures, so each tool must be signed after merging. Ad-hoc signing is
# enough for a local app. A failed signature must stop the build: on Apple silicon, unsigned
# code simply won't launch.
for tool in ffmpeg ffprobe jq; do
	codesign --force --sign - "$APP/Contents/Resources/engine/$tool" \
		|| { echo "ERROR: failed to sign $tool"; exit 1; }
done

# Sign the executable
codesign --force --sign - "$APP/Contents/MacOS/LogGrade" \
	|| { echo "ERROR: failed to sign LogGrade executable"; exit 1; }

# Sign the bundle last, and verify it reached all executables inside
codesign --force --sign - "$APP" \
	|| { echo "ERROR: failed to sign app bundle"; exit 1; }
codesign --verify --deep --strict "$APP" \
	|| { echo "ERROR: code signature verification failed"; exit 1; }

# TELL THE SYSTEM THE BUNDLE CHANGED, or Finder keeps showing the generic application icon.
# macOS caches an app's icon against its PATH, and this script deletes and recreates the bundle at
# the same path on every build — so the cache is never invalidated and the app looks like it has
# no icon at all, however correct the .icns inside it is. Touching the bundle and re-registering it
# is what makes Finder look again.
touch "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1
echo "built $APP ($CONFIG)"
