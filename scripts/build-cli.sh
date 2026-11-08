#!/usr/bin/env bash
# Baut das Kommandozeilen-Tool `zipp` (Universal: Apple Silicon + Intel) und
# packt es als .tar.gz. Signiert und notarisiert, wenn die Variablen gesetzt sind
# (wie bei make-dmg.sh: DEVELOPER_ID, NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID).
#
# Aufruf:  scripts/build-cli.sh [Ziel.tar.gz]
# Ergebnis: build/cli/zipp und das Archiv (Standard: build/zipp-cli-macos.tar.gz)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_TAR="${1:-$ROOT/build/zipp-cli-macos.tar.gz}"
OUT_DIR="$ROOT/build/cli"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "▸ zipp-CLI (universal)"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  (cd "$ROOT/core" && cargo build --release --locked -p zipp-cli --target "$target")
done
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
lipo -create \
  "$ROOT/core/target/aarch64-apple-darwin/release/zipp" \
  "$ROOT/core/target/x86_64-apple-darwin/release/zipp" \
  -output "$OUT_DIR/zipp"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "▸ Signieren"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$OUT_DIR/zipp"
  if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    echo "▸ Notarisieren"
    ditto -c -k "$OUT_DIR/zipp" "$OUT_DIR/zipp.zip"
    xcrun notarytool submit "$OUT_DIR/zipp.zip" --wait \
      --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
    rm "$OUT_DIR/zipp.zip"
  fi
else
  codesign --force --sign - "$OUT_DIR/zipp"
fi

cp "$ROOT/third_party/unrar/license.txt" "$OUT_DIR/UNRAR-LICENSE.txt"
tar -czf "$OUT_TAR" -C "$OUT_DIR" zipp UNRAR-LICENSE.txt
(cd "$(dirname "$OUT_TAR")" && shasum -a 256 "$(basename "$OUT_TAR")" > "$(basename "$OUT_TAR").sha256")
echo "✓ $OUT_TAR ($(lipo -archs "$OUT_DIR/zipp"))"
