#!/bin/bash
# Builds Goi.app into dist/ from the SPM GoiApp product.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product GoiApp

APP=dist/Goi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GoiApp</string>
    <key>CFBundleIdentifier</key><string>com.etng.goi</string>
    <key>CFBundleName</key><string>Goi</string>
    <key>CFBundleDisplayName</key><string>Goi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
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

codesign --force --sign - "$APP" >/dev/null 2>&1

echo "built $APP"
echo "run:  open $APP"
