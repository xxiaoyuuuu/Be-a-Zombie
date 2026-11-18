#!/bin/bash
# Builds ZombiePet.app and installs it in ~/Applications.
# Needs the Xcode Command Line Tools (swiftc). Set ZOMBIE_APP_DIR to install somewhere else.
set -euo pipefail
cd "$(dirname "$0")"

OUT="${ZOMBIE_APP_DIR:-$HOME/Applications}"
# Build outside the project folder: folders synced by iCloud add file attributes
# that code signing refuses.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/ZombiePet.app"
FLAGS=()

# Some Command Line Tools updates leave an old module.modulemap beside the new
# bridging.modulemap, which breaks every Swift build ("redefinition of module
# 'SwiftBridging'"). Hide the stale file for this build instead of touching /Library.
INC="/Library/Developer/CommandLineTools/usr/include/swift"
if [ -f "$INC/module.modulemap" ] && [ -f "$INC/bridging.modulemap" ]; then
    : > "$WORK/empty.modulemap"
    cat > "$WORK/overlay.yaml" <<EOF
{
  "version": 0,
  "roots": [
    {
      "name": "$INC",
      "type": "directory",
      "contents": [
        { "name": "module.modulemap", "type": "file", "external-contents": "$WORK/empty.modulemap" }
      ]
    }
  ]
}
EOF
    FLAGS+=(-vfsoverlay "$WORK/overlay.yaml")
fi

mkdir -p "$APP/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos13.0" ${FLAGS[@]+"${FLAGS[@]}"} \
    -o "$APP/Contents/MacOS/ZombiePet" Sources/*.swift -framework AppKit
cp Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"

mkdir -p "$OUT"
rm -rf "$OUT/ZombiePet.app"
cp -R "$APP" "$OUT/"
echo "Installed $OUT/ZombiePet.app"
