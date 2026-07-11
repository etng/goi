#!/bin/bash
# Renders assets/icon/goi-icon.svg into AppIcon.icns (all sizes) and a small
# ribbon logo PNG. Requires rsvg-convert (brew install librsvg) + iconutil.
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="assets/icon/goi-icon.svg"
OUT="assets/icon"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

render() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2"; }

render 16   "$SET/icon_16x16.png"
render 32   "$SET/icon_16x16@2x.png"
render 32   "$SET/icon_32x32.png"
render 64   "$SET/icon_32x32@2x.png"
render 128  "$SET/icon_128x128.png"
render 256  "$SET/icon_128x128@2x.png"
render 256  "$SET/icon_256x256.png"
render 512  "$SET/icon_256x256@2x.png"
render 512  "$SET/icon_512x512.png"
render 1024 "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"

# ribbon logo (used in-app), @2x for retina
render 96 "$OUT/logo.png"

echo "built $OUT/AppIcon.icns and $OUT/logo.png"
