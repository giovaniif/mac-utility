#!/bin/bash
# Builds a Developer ID signed, notarized and stapled DMG in build-release/.
#
# Needs a "Developer ID Application" certificate in the keychain and
# notarization credentials saved with:
#   xcrun notarytool store-credentials mac-utility --apple-id <email> --team-id 827UMZ89C2
#
# Usage: scripts/release.sh   (version comes from MARKETING_VERSION in project.yml)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-mac-utility}"
TEAM=827UMZ89C2
IDENTITY="Developer ID Application"
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
OUT=build-release
APP="$OUT/Build/Products/Release/MacUtility.app"
DMG="$OUT/MacUtility-$VERSION.dmg"

echo "==> Building $VERSION"
xcodegen generate >/dev/null
xcodebuild -project MacUtility.xcodeproj -scheme MacUtility -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath "$OUT" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build -quiet
codesign --verify --deep --strict "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "The app still has get-task-allow; notarization would reject it" >&2
  exit 1
fi

# notarytool exits 0 even when Apple rejects the upload, so check the status.
notarize() {
  local output
  output=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)
  echo "$output" | grep -E "id:|status:" | tail -2
  if ! echo "$output" | grep -q "status: Accepted"; then
    local id
    id=$(echo "$output" | sed -n 's/^ *id: //p' | head -1)
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/MacUtility.zip"
notarize "$OUT/MacUtility.zip"
xcrun stapler staple "$APP"
rm "$OUT/MacUtility.zip"

echo "==> Building the DMG"
rm -rf "$OUT/dmg" "$DMG"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Mac Utility.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Mac Utility" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> Checking Gatekeeper"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"
shasum -a 256 "$DMG"
