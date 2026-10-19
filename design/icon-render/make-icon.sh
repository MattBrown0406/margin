#!/bin/sh
# Rebuilds the Stabilis app icon (a Roman gold coin with a laurel wreath and an S, on charcoal granite) and the
# in-app logo. Needs python3 with numpy + Pillow, and ImageMagick.
#   python3 -m venv /tmp/icon-venv && /tmp/icon-venv/bin/pip install numpy pillow
#   PY=/tmp/icon-venv/bin/python sh design/icon-render/make-icon.sh
# The lettering is Cinzel (fonts/, SIL Open Font License), a typeface drawn from Roman inscriptional capitals.
set -e
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
"${PY:-python3}" design/icon-render/slab.py "$OUT" 3 plain
"${PY:-python3}" design/icon-render/logos.py "$OUT" "$OUT/face.png" design/icon-render/fonts/Cinzel-Bold.ttf
# iOS applies the rounded mask. App Store icons must have no alpha.
magick "$OUT/4-coin.png" -strip -alpha off -define png:color-type=2 design/Stabilis-App-Icon-1024.png
cp design/Stabilis-App-Icon-1024.png ios/Margin/Assets.xcassets/AppIcon.appiconset/Stabilis-App-Icon-1024.png
for s in 1:46 2:92 3:138; do   # shown at 46 pt in the Today header
  magick design/Stabilis-App-Icon-1024.png -resize "${s#*:}x${s#*:}" -strip -alpha off "ios/Margin/Assets.xcassets/MarginLogo.imageset/MarginLogo-${s%%:*}x.png"
done
echo "Icon rebuilt."
