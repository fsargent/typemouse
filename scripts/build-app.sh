#!/bin/bash
# Builds TypeMouse.app, signs it with the stable identity, and installs it in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${TYPEMOUSE_SIGN_IDENTITY:-TypeMouse Dev}"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/TypeMouse.app"

if [ -d /Applications/Xcode.app ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TypeMouse"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Replace the binary in place. Keeping the same path keeps the Accessibility grant.
cp "$BIN" "$APP/Contents/MacOS/TypeMouse"

codesign --force --sign "$IDENTITY" --identifier dev.fsargent.typemouse "$APP"
codesign --verify --verbose=1 "$APP"
echo "Installed $APP"
