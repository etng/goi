#!/bin/bash
# Builds the release (universal) app and packages it into a drag-to-install
# DMG: Goi.app beside an Applications symlink.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=1 ./scripts/make-app.sh

VERSION="$(tr -d '[:space:]' < VERSION)"
STAGE="$(mktemp -d)/Goi"
mkdir -p "$STAGE"
cp -R "dist/Goi.app" "$STAGE/Goi.app"
ln -s /Applications "$STAGE/Applications"

rm -f dist/Goi.dmg
hdiutil create -volname "Goi" -srcfolder "$STAGE" -ov -format UDZO dist/Goi.dmg >/dev/null

echo "built dist/Goi.dmg (version ${VERSION})"
