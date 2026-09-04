#!/bin/bash
#
# Compila AlbumExport en Release, la firma para distribuirla entre Macs propios
# y deja un .zip en dist/. No pasa por el App Store.
#
# Firma: usa "Developer ID Application" si existe en el llavero (permite abrir la
# app en otros Macs sin avisos tras notarizar); si no, deja la firma automática
# de desarrollo. En ese caso, en el otro Mac hay que abrirla con clic derecho >
# Abrir (o quitar la cuarentena: xattr -dr com.apple.quarantine AlbumExport.app).
#
# Uso: scripts/build_release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# DerivedData fuera de iCloud: los atributos extendidos que añade iCloud Drive
# ("resource fork, Finder information, or similar detritus") hacen fallar codesign.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/AlbumExport-release"

xcodegen generate
xcodebuild build -project AlbumExport.xcodeproj -scheme AlbumExport -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' | grep -E "error:|warning:|BUILD" || true

APP="$DERIVED/Build/Products/Release/AlbumExport.app"
[ -d "$APP" ] || { echo "No se generó $APP"; exit 1; }

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
if [ -n "$IDENTITY" ]; then
  echo "Firmando con: $IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
  # Notarizar (requiere un perfil guardado: xcrun notarytool store-credentials notary):
  #   ditto -c -k --keepParent "$APP" dist/AlbumExport-notary.zip
  #   xcrun notarytool submit dist/AlbumExport-notary.zip --keychain-profile notary --wait
  #   xcrun stapler staple "$APP"
else
  echo "Sin certificado Developer ID: se mantiene la firma de desarrollo (Apple Development)."
fi
codesign --verify --verbose=2 "$APP"

mkdir -p dist
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
ZIP="dist/AlbumExport-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Listo: $ZIP"
