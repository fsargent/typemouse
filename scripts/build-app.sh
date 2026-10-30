#!/bin/bash
# Builds TypeMouse.app, signs it with the stable identity, and installs it in ~/Applications.
#
# Environment:
#   TYPEMOUSE_SIGN_IDENTITY  signing identity, or "-" for an ad-hoc signature (CI)
#   DEST                     folder for TypeMouse.app (default ~/Applications)
#   VERSION                  sets CFBundleShortVersionString, for example 0.2.0
#   UNIVERSAL=1              builds for Apple silicon and Intel
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${TYPEMOUSE_SIGN_IDENTITY:-TypeMouse Dev}"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/TypeMouse.app"

if [ -d /Applications/Xcode.app ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCHS=()
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/TypeMouse"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
# Replace the binary in place. Keeping the same path keeps the Accessibility grant.
cp "$BIN" "$APP/Contents/MacOS/TypeMouse"

codesign --force --sign "$IDENTITY" --identifier dev.fsargent.typemouse "$APP"
codesign --verify --verbose=1 "$APP"
echo "Installed $APP"
