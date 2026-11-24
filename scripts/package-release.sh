#!/bin/bash
# Notarize a signed app, staple its ticket, and verify the final ZIP.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 TypeMouse.app output.zip notary-profile" >&2
  exit 2
fi
app="$1"
archive="$2"
profile="$3"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

codesign --verify --strict "$app"
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<< "$signature"; then
  echo "The app must have a Developer ID Application signature." >&2
  exit 1
fi
architectures="$(lipo -archs "$app/Contents/MacOS/TypeMouse")"
if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
  echo "The app must support both arm64 and x86_64. Found: $architectures" >&2
  exit 1
fi

notary_options=(--keychain-profile "$profile")
if [ -n "${NOTARY_KEYCHAIN:-}" ]; then
  notary_options+=(--keychain "$NOTARY_KEYCHAIN")
fi
ditto -c -k --keepParent "$app" "$work/submission.zip"
response="$(xcrun notarytool submit "$work/submission.zip" "${notary_options[@]}" \
  --wait --timeout 45m --output-format json)"
printf '%s\n' "$response"
if ! jq -e '.status == "Accepted"' <<< "$response" >/dev/null; then
  submission="$(jq -r '.id' <<< "$response")"
  xcrun notarytool log "$submission" "${notary_options[@]}"
  exit 1
fi

xcrun stapler staple "$app"
ditto -c -k --keepParent "$app" "$work/notarized.zip"
ditto -x -k "$work/notarized.zip" "$work/check"
extracted="$work/check/$(basename "$app")"
xcrun stapler validate "$extracted"
codesign --verify --strict "$extracted"
spctl --assess --type execute --verbose=2 "$extracted"
mv "$work/notarized.zip" "$archive"
(cd "$(dirname "$archive")" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
