#!/bin/bash
# Regenera assets/VitalScan.icns a partir de scripts/make_icon.swift (CoreGraphics).
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
swiftc -O "$PROJ/scripts/make_icon.swift" -o "$TMP/mk"
"$TMP/mk" "$PROJ/assets/icon_master.png"
ICO="$TMP/VitalScan.iconset"; mkdir -p "$ICO"
g() { sips -z $1 $1 "$PROJ/assets/icon_master.png" --out "$ICO/$2" >/dev/null; }
g 16 icon_16x16.png; g 32 icon_16x16@2x.png; g 32 icon_32x32.png; g 64 icon_32x32@2x.png
g 128 icon_128x128.png; g 256 icon_128x128@2x.png; g 256 icon_256x256.png
g 512 icon_256x256@2x.png; g 512 icon_512x512.png
cp "$PROJ/assets/icon_master.png" "$ICO/icon_512x512@2x.png"
iconutil -c icns "$ICO" -o "$PROJ/assets/VitalScan.icns"
echo "✓ assets/VitalScan.icns atualizado"
