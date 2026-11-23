#!/bin/bash
# Copies the shared catalog and icons into docs/ (the GitHub Pages site).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/icons
{ printf 'window.CATALOG = '; cat catalog.json; printf ';\n'; } > docs/catalog.js
cp icons/*.png docs/icons/
if [ -f launcher/Resources/AppIcon.icns ]; then
  sips -s format png -z 256 256 launcher/Resources/AppIcon.icns --out docs/icons/Workbench.png >/dev/null
fi
python3 scripts/build-releases.py
echo "Site assets updated in docs/"
