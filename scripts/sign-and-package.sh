#!/usr/bin/env bash
# Usage: sign-and-package.sh <path/to/Synapse.app> <version>
set -euo pipefail

APP="${1:?usage: $0 <Synapse.app> <version>}"
VERSION="${2:?usage: $0 <Synapse.app> <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="$ROOT/dist/Synapse-$VERSION.zip"
DMG="$ROOT/dist/Synapse-$VERSION.dmg"
# Built by xcodebuild -derivedDataPath build alongside the Sparkle package.
SIGN_UPDATE="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
mkdir -p "$ROOT/dist"

KC=""
ORIG_KEYCHAINS=""
cleanup() {
  if [[ -n "$KC" ]]; then
    # shellcheck disable=SC2086
    [[ -n "$ORIG_KEYCHAINS" ]] && security list-keychains -d user -s $ORIG_KEYCHAINS || true
    security delete-keychain "$KC" 2>/dev/null || true
  fi
}
trap cleanup EXIT

SIGNED=0
if [[ -n "${DEVELOPER_ID_CERT_P12:-}" ]]; then
  KC="${RUNNER_TEMP:-$(mktemp -d)}/synapse-signing.keychain-db"
  KC_PASS="$(uuidgen)"
  ORIG_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | xargs)"
  P12="$(mktemp -t synapse-cert).p12"
  echo "$DEVELOPER_ID_CERT_P12" | base64 --decode > "$P12"
  security create-keychain -p "$KC_PASS" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KC_PASS" "$KC"
  security import "$P12" -k "$KC" -P "${DEVELOPER_ID_CERT_PASSWORD:-}" -T /usr/bin/codesign
  rm -f "$P12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KC" $ORIG_KEYCHAINS
  IDENTITY="$(security find-identity -v -p codesigning "$KC" | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
  [[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found in p12" >&2; exit 1; }
  TS=(--timestamp)
  SIGNED=1
else
  echo "No DEVELOPER_ID_CERT_P12: ad-hoc signing"
  IDENTITY="-"
  TS=()
fi

sign() { codesign --force --options runtime ${TS[@]+"${TS[@]}"} -s "$IDENTITY" "$1"; }

# Helper binaries first (inside out); notarization rejects any nested code without Developer ID and hardened runtime.
for helper in ffmpeg llama-server; do sign "$APP/Contents/MacOS/$helper"; done
# Sparkle's nested helpers, in the order its docs give; Downloader keeps its own entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE" ]]; then
  sign "$SPARKLE/XPCServices/Installer.xpc"
  codesign --force --options runtime ${TS[@]+"${TS[@]}"} --preserve-metadata=entitlements -s "$IDENTITY" "$SPARKLE/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Autoupdate"
  sign "$SPARKLE/Updater.app"
fi
if [[ -d "$APP/Contents/Frameworks" ]]; then
  for f in "$APP"/Contents/Frameworks/*; do
    [[ -e "$f" ]] && sign "$f"
  done
fi
# The Release build is unsigned (CODE_SIGNING_ALLOWED=NO), so the entitlements are applied here.
codesign --force --options runtime ${TS[@]+"${TS[@]}"} --entitlements "$ROOT/Synapse/Synapse.entitlements" -s "$IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$APP"
# Capture first: with pipefail, `grep -q` closing the pipe early makes codesign's SIGPIPE fail the check.
for helper in ffmpeg llama-server; do
  SIG="$(codesign -dv "$APP/Contents/MacOS/$helper" 2>&1)"
  [[ "$SIG" == *runtime* ]] || { echo "$helper is missing the hardened runtime flag" >&2; exit 1; }
done
ENT="$(codesign -d --entitlements - "$APP" 2>&1)"
[[ "$ENT" == *audio-input* ]] || { echo "Synapse.app is missing its entitlements" >&2; exit 1; }

# The DMG people download: the app beside an Applications link to drag it onto.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Synapse.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Synapse -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
[[ "$SIGNED" == 1 ]] && codesign --force ${TS[@]+"${TS[@]}"} -s "$IDENTITY" "$DMG"

# One notarization covers the DMG and the app inside it, so both can be stapled.
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

# The zip is what Sparkle downloads.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# appcast.xml is published with each release; the app's SUFeedURL points at the latest release's copy.
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  KEY_FILE="$(mktemp)"
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE"
  ENCLOSURE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ZIP")"
  rm -f "$KEY_FILE"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  PAGE="https://github.com/KyleBoyer/synapse/releases/tag/v$VERSION"
  cat > "$ROOT/dist/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Synapse</title>
    <item>
      <title>Synapse $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$PAGE</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>Synapse $VERSION is available. <a href="$PAGE">Read the release notes</a>.</p>]]></description>
      <enclosure url="https://github.com/KyleBoyer/synapse/releases/download/v$VERSION/Synapse-$VERSION.zip" type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML
fi

echo "Wrote $ZIP and $DMG (SIGNED=$SIGNED)"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "signed=$SIGNED" >> "$GITHUB_OUTPUT"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "SIGNED=$SIGNED" >> "$GITHUB_OUTPUT"
exit 0
