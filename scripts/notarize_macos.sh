#!/usr/bin/env bash
set -euo pipefail

# Official macOS Developer ID signing + Apple Notarization + Stapling script for Vibepollo.
# Usage:
#   ./scripts/notarize_macos.sh [--profile <notarytool-keychain-profile>]
#   or with App Store Connect API Key env vars:
#   ASC_KEY_PATH=~/Downloads/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=UUID ./scripts/notarize_macos.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DMG="${OUT_DMG:-$REPO_ROOT/../Vibepollo-macOS-arm64.dmg}"
NOTARY_PROFILE="${NOTARY_PROFILE:-vibepollo-notary}"
INSTALL_LOCAL="${INSTALL_LOCAL:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --out)
      OUT_DMG="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# 1. Auto-import any newly downloaded Developer ID certificate from ~/Downloads if present
shopt -s nullglob
for cer in "$HOME"/Downloads/developerID_application*.cer; do
  echo "==> Importing certificate: $cer"
  security import "$cer" -k "$HOME/Library/Keychains/login.keychain-db" || true
done
shopt -u nullglob

# 2. Detect Developer ID Application identity
DEV_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
if [[ -z "$DEV_ID" ]]; then
  echo "ERROR: No valid 'Developer ID Application' identity found in keychain." >&2
  echo "Upload Vibepollo-DeveloperID.certSigningRequest at https://developer.apple.com/account/resources/certificates/add" >&2
  exit 1
fi
echo "==> Using signing identity: $DEV_ID"

# 3. Configure, build, bundle, and sign with Hardened Runtime + entitlements.plist
cd "$REPO_ROOT"
OPENSSL_ARGS=()
if [[ -z "${OPENSSL_ROOT_DIR:-}" ]] && command -v brew >/dev/null 2>&1; then
  BREW_OPENSSL="$(brew --prefix openssl@3 2>/dev/null || true)"
  if [[ -n "$BREW_OPENSSL" && -d "$BREW_OPENSSL" ]]; then
    OPENSSL_ARGS+=("-DOPENSSL_ROOT_DIR=$BREW_OPENSSL")
  fi
fi

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTS=OFF \
  -DOPENSSL_USE_STATIC_LIBS=ON \
  -DAPPLE_CODESIGN_IDENTITY="$DEV_ID" \
  "${OPENSSL_ARGS[@]}"
cmake --build build --target sunshine -j"$(sysctl -n hw.ncpu)"

rm -rf build/bundle_stage
SHOULD_SIGN=true cmake --install build --prefix "$REPO_ROOT/build/bundle_stage"

APP_BUNDLE="$REPO_ROOT/build/bundle_stage/Vibepollo.app"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# 4. Create and sign DMG
rm -f "$OUT_DMG"
hdiutil create -volname "Vibepollo" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$OUT_DMG"
codesign --force --sign "$DEV_ID" --timestamp "$OUT_DMG"

# 5. Submit DMG to Apple Notary Service and wait
echo "==> Submitting $(basename "$OUT_DMG") to Apple Notary Service..."
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  xcrun notarytool submit "$OUT_DMG" \
    --key "$ASC_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait
else
  xcrun notarytool submit "$OUT_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
fi

# 6. Staple notarization ticket to both DMG and .app, then deploy to /Applications
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$OUT_DMG"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$OUT_DMG"
xcrun stapler validate "$APP_BUNDLE"

echo "==> Verifying Gatekeeper acceptance..."
spctl -a -vvv -t exec "$APP_BUNDLE"

if [[ "$INSTALL_LOCAL" == "1" ]]; then
  echo "==> Updating /Applications/Vibepollo.app..."
  rsync -a --delete "$APP_BUNDLE/" /Applications/Vibepollo.app/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Vibepollo.app || true
  pkill -TERM -f "/Applications/Vibepollo.app/Contents/MacOS/Vibepollo" 2>/dev/null || true
  for _ in $(seq 1 25); do
    pgrep -f "/Applications/Vibepollo.app/Contents/MacOS/Vibepollo" >/dev/null 2>&1 || break
    sleep 0.2
  done
  open -g /Applications/Vibepollo.app
fi

echo "==> Done! Notarized DMG ready at: $OUT_DMG"
