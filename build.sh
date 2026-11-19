#!/bin/bash
# Crea build/Calcoletti.app e build/Calcoletti.dmg (serve un Mac con gli strumenti di Xcode).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Calcoletti"
APP="$NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Mancano gli 'Strumenti da riga di comando' di Xcode."
    echo "Si apre ora la finestra di installazione: conferma, aspetta che finisca e rilancia."
    xcode-select --install || true
    exit 1
fi

rm -rf build
mkdir -p "build/$APP/Contents/MacOS" "build/$APP/Contents/Resources"

# Compila per Apple Silicon e Intel e unisce i due in un'unica app (funziona su ogni Mac).
echo "→ Compilo ${NAME} ${VERSION}…"
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -parse-as-library \
        -target "${ARCH}-apple-macos13.0" \
        Sources/*.swift -o "build/$NAME-$ARCH"
done
lipo -create "build/$NAME-arm64" "build/$NAME-x86_64" -output "build/$APP/Contents/MacOS/$NAME"
rm -f "build/$NAME-arm64" "build/$NAME-x86_64"

cp Info.plist "build/$APP/Contents/Info.plist"

echo "→ Icona…"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Resources/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "build/$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --deep --sign - "build/$APP" >/dev/null 2>&1 || true
xattr -cr "build/$APP" 2>/dev/null || true

echo "→ Creo il file di installazione $NAME.dmg…"
STAGE="build/dmg"
mkdir -p "$STAGE"
cp -R "build/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applicazioni"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "build/$NAME.dmg" >/dev/null
rm -rf "$STAGE"

echo "✓ Pronti: build/$APP e build/$NAME.dmg"
