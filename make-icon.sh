#!/bin/bash
# Rebuilds Resources/AppIcon.icns from Resources/AppIcon.svg.
# Needed only after editing the SVG: the ready .icns is in the repository.
# Requires rsvg-convert: brew install librsvg
set -euo pipefail
cd "$(dirname "$0")"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" Resources/AppIcon.svg -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) Resources/AppIcon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Готово: Resources/AppIcon.icns"
