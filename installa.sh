#!/bin/bash
# Compila Calcoletti, lo installa in Applicazioni e mette Calcoletti.dmg sulla Scrivania.
# Uso: nel Terminale, dentro questa cartella:  bash installa.sh
set -euo pipefail
cd "$(dirname "$0")"

bash build.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

echo "→ Installo in $DEST…"
pkill -x Calcoletti 2>/dev/null || true
pkill -x Scontrino 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/Calcoletti.app" "$DEST/Scontrino.app"
cp -R build/Calcoletti.app "$DEST/"
cp build/Calcoletti.dmg "$HOME/Desktop/Calcoletti.dmg"
open "$DEST/Calcoletti.app"

echo ""
echo "✓ Fatto. L'icona della farfalla è nella barra in alto a destra."
echo "  Sulla Scrivania trovi Calcoletti.dmg: è il file per installarla su altri Mac."
