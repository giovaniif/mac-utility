#!/bin/bash
# Builds MacUtility.app on a macOS runner and zips it as MacUtility-<sha>.zip.
#
# With MACOS_CERTIFICATE set, it signs with the Developer ID Application
# identity, the same one releases use, so macOS keeps the permission grants
# (Accessibility, Screen Recording, Input Monitoring) of the installed app when
# a CI build replaces it. Without it, it signs ad-hoc: still a compile check,
# but macOS treats that build as a different app.
#
# Secrets (env): MACOS_CERTIFICATE (base64 .p12 with the Developer ID
# Application cert and key), MACOS_CERTIFICATE_PASSWORD. For NOTARIZE=1 also
# MACOS_NOTARY_APPLE_ID, MACOS_NOTARY_PASSWORD (app-specific password).
set -euo pipefail
cd "$(dirname "$0")/../.."

TEAM=827UMZ89C2
OUT=build
APP="$OUT/Build/Products/Release/MacUtility.app"
sha="$(git rev-parse --short HEAD)"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
zip="MacUtility-$sha.zip"

xcodegen generate

build() {
  xcodebuild -project MacUtility.xcodeproj -scheme MacUtility -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$OUT" \
    -clonedSourcePackagesDirPath "$OUT/SourcePackages" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "$@" build | tee "$tmp/xcodebuild.log" | pretty
}

pretty() {
  if command -v xcbeautify >/dev/null; then xcbeautify --renderer github-actions; else cat; fi
}

if [ -z "${MACOS_CERTIFICATE:-}" ]; then
  echo "::warning::MACOS_CERTIFICATE is not set: ad-hoc signature, macOS will ask for permissions again"
  build CODE_SIGN_IDENTITY=-
  ditto -c -k --keepParent "$APP" "$zip"
  exit 0
fi

if [ -z "${MACOS_CERTIFICATE_PASSWORD:-}" ]; then
  echo "::error::MACOS_CERTIFICATE_PASSWORD is not set"
  exit 1
fi

# A throwaway keychain holding only the signing identity.
keychain="$tmp/signing.keychain-db"
kc_pass="$(uuidgen)"
trap 'security delete-keychain "$keychain" 2>/dev/null || true; rm -f "$tmp/cert.p12"' EXIT
security create-keychain -p "$kc_pass" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$kc_pass" "$keychain"
printf %s "$MACOS_CERTIFICATE" | base64 --decode > "$tmp/cert.p12"
security import "$tmp/cert.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
rm -f "$tmp/cert.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pass" "$keychain" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

identity="$(security find-identity -v -p codesigning "$keychain" \
  | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
if [ -z "$identity" ]; then
  echo "::error::The certificate holds no Developer ID Application identity"
  security find-identity -v -p codesigning "$keychain"
  exit 1
fi
echo "Signing as: $identity"

build CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $keychain"
codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "::error::The app has get-task-allow; notarization would reject it"
  exit 1
fi

notarize() {
  out="$tmp/notary.json"
  xcrun notarytool submit "$1" \
    --apple-id "$MACOS_NOTARY_APPLE_ID" --password "$MACOS_NOTARY_PASSWORD" \
    --team-id "$TEAM" --wait --timeout 45m --output-format json | tee "$out"
  status="$(plutil -extract status raw -o - "$out")"
  if [ "$status" != Accepted ]; then
    id="$(plutil -extract id raw -o - "$out")"
    echo "::error::Notarization of $1 ended as $status"
    xcrun notarytool log "$id" \
      --apple-id "$MACOS_NOTARY_APPLE_ID" --password "$MACOS_NOTARY_PASSWORD" --team-id "$TEAM" || true
    exit 1
  fi
}

if [ "${NOTARIZE:-0}" = 1 ]; then
  for v in MACOS_NOTARY_APPLE_ID MACOS_NOTARY_PASSWORD; do
    if [ -z "${!v:-}" ]; then
      echo "::error::$v is not set"
      exit 1
    fi
  done
  ditto -c -k --keepParent "$APP" "$tmp/notarize.zip"
  notarize "$tmp/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"

  # The release DMG, as scripts/release.sh makes it.
  version=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
  dmg="MacUtility-$version.dmg"
  rm -rf "$tmp/dmg" "$dmg"
  mkdir -p "$tmp/dmg"
  ditto "$APP" "$tmp/dmg/Mac Utility.app"
  ln -s /Applications "$tmp/dmg/Applications"
  hdiutil create -volname "Mac Utility" -srcfolder "$tmp/dmg" -ov -format UDZO "$dmg" >/dev/null
  codesign --sign "$identity" --timestamp "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg"
  shasum -a 256 "$dmg"
fi

ditto -c -k --keepParent "$APP" "$zip"
