#!/bin/bash
# Builds Goi.app and zips it into dist/Goi.zip for release.
set -euo pipefail
cd "$(dirname "$0")/.."

# release identity for published artifacts
RELEASE=1 ./scripts/make-app.sh

VERSION="$(tr -d '[:space:]' < VERSION)"
( cd dist && /usr/bin/ditto -c -k --keepParent "Goi.app" "Goi.zip" )
echo "built dist/Goi.zip (version ${VERSION})"
