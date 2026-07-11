#!/bin/bash
# Builds the dev variant and installs it to /Applications as "Goi (Dev).app".
# Distinct bundle id (com.etng.goi.dev) so it coexists with an installed
# production Goi and keeps its own Accessibility permission.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

DEST="/Applications/Goi (Dev).app"
rm -rf "$DEST"
cp -R "dist/Goi (Dev).app" "$DEST"
echo "installed $DEST"
echo "open with: open -a 'Goi (Dev)'"
