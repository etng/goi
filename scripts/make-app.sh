#!/bin/bash
# Builds Goi.app into dist/.
#   RELEASE=1  -> production identity  (com.etng.goi,     "Goi")
#   default    -> dev identity         (com.etng.goi.dev, "Goi (Dev)")
# The distinct bundle id keeps a locally-run dev build's Accessibility grant
# (for 划词取词) from colliding with an installed production build's.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product GoiApp
VERSION="$(tr -d '[:space:]' < VERSION)"

if [[ "${RELEASE:-0}" == "1" ]]; then
  APP_NAME="Goi"
  BUNDLE_ID="com.etng.goi"
else
  APP_NAME="Goi (Dev)"
  BUNDLE_ID="com.etng.goi.dev"
fi

APP="dist/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GoiApp</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

cp .build/release/GoiApp "$APP/Contents/MacOS/GoiApp"

# donation QR codes shown on the About page
if compgen -G "assets/donate/*.png" >/dev/null || compgen -G "assets/donate/*.jpg" >/dev/null; then
  mkdir -p "$APP/Contents/Resources/donate"
  cp assets/donate/*.png assets/donate/*.jpg "$APP/Contents/Resources/donate/" 2>/dev/null || true
fi

# Prefer the stable self-signed identity (scripts/setup-signing.sh): it gives
# every rebuild the same designated requirement, so macOS keeps the app's
# Accessibility grant (划词取词) instead of dropping it on each cdhash change.
# Falls back to ad-hoc when the identity isn't set up (e.g. CI).
SIGN_KEYCHAIN="$HOME/Library/Keychains/goi-signing.keychain-db"
CERT_NAME="Goi Local Signing"
if [[ "${RELEASE:-0}" != "1" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  security unlock-keychain -p "goi-local-signing" "$SIGN_KEYCHAIN" 2>/dev/null || true
  codesign --force --sign "$CERT_NAME" "$APP" >/dev/null 2>&1
  echo "built $APP  (${BUNDLE_ID}, v${VERSION}, signed: ${CERT_NAME})"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "built $APP  (${BUNDLE_ID}, v${VERSION}, ad-hoc signed)"
fi
