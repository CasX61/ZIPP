#!/usr/bin/env bash
# Verpackt ZIPP.app als DMG. Signiert und notarisiert, wenn die Zugangsdaten
# gesetzt sind – sonst bleibt es bei der Ad-hoc-Signatur (Nutzer müssen die App
# dann beim ersten Start in den Systemeinstellungen freigeben).
#
# Aufruf:  scripts/make-dmg.sh <Pfad/zu/ZIPP.app> <Ausgabe.dmg>
#
# Optionale Umgebungsvariablen:
#   DEVELOPER_ID          z. B. "Developer ID Application: Max Muster (TEAMID)"
#   NOTARY_KEY_PATH       Pfad zur App-Store-Connect-API-Key-Datei (.p8)
#   NOTARY_KEY_ID         Key-ID
#   NOTARY_ISSUER_ID      Issuer-ID
set -euo pipefail

APP="${1:?Pfad zur ZIPP.app fehlt}"
DMG="${2:?Ziel-DMG fehlt}"
VOLUME="ZIPP"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "▸ Signieren mit „$DEVELOPER_ID“"
  # Hardened Runtime + Zeitstempel (ZippCore ist statisch gelinkt, es gibt keine eingebetteten Frameworks)
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "▸ Keine Developer ID gesetzt – Ad-hoc-Signatur bleibt"
fi

echo "▸ DMG erstellen"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Programme"
rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi

if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  echo "▸ Notarisieren (dauert ein paar Minuten)"
  xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$DMG"
else
  echo "▸ Keine Notarisierungsdaten – übersprungen"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG"
