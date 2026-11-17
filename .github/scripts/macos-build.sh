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
# MACOS_NOTARY_APPLE_ID, MACOS_NOTARY_PASSWORD (app-specific password), and
# SPARKLE_PRIVATE_KEY (base64 ed25519 seed) to sign the over-the-air update:
# then it also writes appcast.xml for the release, notes from CHANGELOG.md.
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

# Sparkle ships its helpers signed by its own developers. Notarization wants
# every piece signed by us with the hardened runtime, innermost first, then
# the app again around them (Sparkle's documented order).
sign() { codesign --force --sign "$identity" --options runtime --timestamp --keychain "$keychain" "$@"; }
fw="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$fw" ]; then
  [ -e "$fw/Versions/B/XPCServices/Installer.xpc" ] && sign "$fw/Versions/B/XPCServices/Installer.xpc"
  [ -e "$fw/Versions/B/XPCServices/Downloader.xpc" ] && sign --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
  sign "$fw/Versions/B/Autoupdate"
  sign "$fw/Versions/B/Updater.app"
  sign "$fw"
  sign --preserve-metadata=entitlements,requirements,flags "$APP"
fi
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

  # A release tag must match the version being built.
  if [[ "${GITHUB_REF:-}" == refs/tags/v* ]] && [ "${GITHUB_REF#refs/tags/v}" != "$version" ]; then
    echo "::error::Tag ${GITHUB_REF#refs/tags/} doesn't match MARKETING_VERSION $version"
    exit 1
  fi

  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    sign_update="$(find "$OUT/SourcePackages/artifacts" -type f -name sign_update -perm -u+x | head -1)"
    if [ -z "$sign_update" ]; then
      echo "::error::Sparkle's sign_update wasn't found in the package artifacts"
      exit 1
    fi
    key="$tmp/sparkle.key"
    (umask 077; printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$key")
    signature="$("$sign_update" --ed-key-file "$key" "$dmg")"
    rm -f "$key"
    echo "Update signature: $signature"
    build_number=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
    # The notes are this version's section of CHANGELOG.md, also used for
    # the GitHub release.
    awk -v v="$version" '$0 ~ "^## " v "( |$)" { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md > release-notes.md
    if ! grep -q '[^[:space:]]' release-notes.md; then
      echo "::error::CHANGELOG.md has no section for $version"
      exit 1
    fi
    notes_html="$(python3 .github/scripts/notes-html.py < release-notes.md)"
    cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mac Utility</title>
    <item>
      <title>Mac Utility $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$notes_html]]></description>
      <enclosure url="https://github.com/giovaniif/mac-utility/releases/download/v$version/$dmg" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
    cat appcast.xml
  fi
fi

ditto -c -k --keepParent "$APP" "$zip"
