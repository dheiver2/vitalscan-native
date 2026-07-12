#!/bin/bash
# Compila o VitalScan.app 100% nativo (Swift/SwiftUI) — zero Python.
#
# Uso:   ./build_app.sh [destino]     (destino padrão: ~/Desktop)
# Requer: apenas as Command Line Tools do Xcode (swiftc). Sem dependências.

set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$HOME/Desktop}"
APP="$DEST/VitalScan.app"
ICNS="$PROJ/assets/VitalScan.icns"
BIN_NAME="VitalScan"

echo "▸ Compilando fontes Swift…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework Vision -framework Accelerate -framework CoreVideo \
  "$PROJ"/Sources/*.swift

[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VitalScan</string>
  <key>CFBundleDisplayName</key><string>VitalScan</string>
  <key>CFBundleIdentifier</key><string>ai.mangaba.vitalscan.native</string>
  <key>CFBundleVersion</key><string>3.0.0</string>
  <key>CFBundleShortVersionString</key><string>3.0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>O VitalScan usa a câmera para medir a frequência cardíaca por rPPG (fotopletismografia remota). Nenhuma imagem sai do seu Mac.</string>
</dict>
</plist>
PLIST

# assinatura ad-hoc (necessária p/ o TCC liberar a câmera de forma estável)
echo "▸ Assinando (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# registra no Launch Services
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" 2>/dev/null || true

echo "✓ Criado: $APP"
echo "  Abra com:  open \"$APP\""
