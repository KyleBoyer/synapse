#!/usr/bin/env bash
# Usage: sign-and-package.sh <path/to/Synapse.app> <version>
set -euo pipefail

APP="${1:?usage: $0 <Synapse.app> <version>}"
VERSION="${2:?usage: $0 <Synapse.app> <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="$ROOT/dist/Synapse-$VERSION.zip"
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

sign() { codesign --force --options runtime "${TS[@]}" -s "$IDENTITY" "$1"; }

# Helper binaries first (inside out); notarization rejects any nested code without Developer ID and hardened runtime.
for helper in ffmpeg llama-server; do sign "$APP/Contents/MacOS/$helper"; done
if [[ -d "$APP/Contents/Frameworks" ]]; then
  for f in "$APP"/Contents/Frameworks/*; do
    [[ -e "$f" ]] && sign "$f"
  done
fi
# The Release build is unsigned (CODE_SIGNING_ALLOWED=NO), so the entitlements are applied here.
codesign --force --options runtime "${TS[@]}" --entitlements "$ROOT/Synapse/Synapse.entitlements" -s "$IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$APP"
# Capture first: with pipefail, `grep -q` closing the pipe early makes codesign's SIGPIPE fail the check.
for helper in ffmpeg llama-server; do
  SIG="$(codesign -dv "$APP/Contents/MacOS/$helper" 2>&1)"
  [[ "$SIG" == *runtime* ]] || { echo "$helper is missing the hardened runtime flag" >&2; exit 1; }
done
ENT="$(codesign -d --entitlements - "$APP" 2>&1)"
[[ "$ENT" == *audio-input* ]] || { echo "Synapse.app is missing its entitlements" >&2; exit 1; }

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "Wrote $ZIP (SIGNED=$SIGNED)"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "signed=$SIGNED" >> "$GITHUB_OUTPUT"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "SIGNED=$SIGNED" >> "$GITHUB_OUTPUT"
exit 0
