#!/bin/bash
# Builds the dev variant and installs it to /Applications as "Goi (Dev).app".
# Distinct bundle id (com.etng.goi.dev) so it coexists with an installed
# production Goi and keeps its own Accessibility permission.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

# quit any running dev instance first — `open` only reactivates a running
# copy, so without this you'd keep seeing the old build
pkill -f "Goi (Dev).app/Contents/MacOS/GoiApp" 2>/dev/null || true
sleep 0.5

DEST="/Applications/Goi (Dev).app"
rm -rf "$DEST"
cp -R "dist/Goi (Dev).app" "$DEST"
echo "installed $DEST"

open "$DEST"
echo "launched $DEST"
