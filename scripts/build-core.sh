#!/usr/bin/env bash
# Baut den Rust-Kern (zipp-ffi) für macOS, erzeugt die Swift-Bindings und
# verpackt alles als ZippCoreFFI.xcframework.
#
# Aufruf:  scripts/build-core.sh [debug|release]
# Umgebung:
#   ZIPP_NATIVE_ONLY=1   nur für die aktuelle Architektur bauen (schneller beim Entwickeln)
#
# Ausgabe (nicht im Git, wird immer neu erzeugt):
#   app/ZippCore/Generated/zipp_ffi.swift
#   app/ZippCore/Generated/ZippCoreFFI.xcframework
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
GEN="$ROOT/app/ZippCore/Generated"
WORK="$CORE/target/zipp-xcframework"
MODE="${1:-release}"

# Xcode-Build-Phasen haben einen minimalen PATH
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
# In Xcode-Build-Phasen liegt der echte clang im PATH (nicht der xcrun-Shim) –
# ohne explizites SDK findet er die System-Header nicht.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

case "$MODE" in
  release) PROFILE_FLAG="--release"; PROFILE_DIR="release" ;;
  debug)   PROFILE_FLAG="";          PROFILE_DIR="debug" ;;
  *) echo "Unbekannter Modus: $MODE (debug|release)" >&2; exit 1 ;;
esac

if [[ "${ZIPP_NATIVE_ONLY:-0}" == "1" ]]; then
  case "$(uname -m)" in
    arm64) TARGETS=(aarch64-apple-darwin) ;;
    *)     TARGETS=(x86_64-apple-darwin) ;;
  esac
else
  TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
fi

command -v cargo >/dev/null || { echo "error: cargo nicht gefunden – bitte Rust installieren (https://rustup.rs)" >&2; exit 1; }
for t in "${TARGETS[@]}"; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

echo "▸ Rust-Kern bauen ($MODE: ${TARGETS[*]})"
LIBS=()
for t in "${TARGETS[@]}"; do
  cargo build --manifest-path "$CORE/Cargo.toml" -p zipp-ffi $PROFILE_FLAG --target "$t"
  LIBS+=("$CORE/target/$t/$PROFILE_DIR/libzipp_ffi.a")
done

rm -rf "$WORK"
mkdir -p "$WORK/include" "$WORK/swift"

echo "▸ Universal-Bibliothek"
lipo -create "${LIBS[@]}" -output "$WORK/libzipp_ffi.a"

echo "▸ Swift-Bindings erzeugen"
# Die Metadaten stehen in der dynamischen Bibliothek des ersten Targets.
# uniffi ruft `cargo metadata` im aktuellen Ordner auf (für uniffi.toml).
(cd "$CORE" && cargo run -q -p uniffi-bindgen -- \
  --swift-sources --headers --modulemap \
  --module-name ZippCoreFFI --modulemap-filename module.modulemap \
  "$CORE/target/${TARGETS[0]}/$PROFILE_DIR/libzipp_ffi.dylib" "$WORK/swift")
mv "$WORK/swift/"*.h "$WORK/swift/module.modulemap" "$WORK/include/"

echo "▸ XCFramework"
xcodebuild -create-xcframework \
  -library "$WORK/libzipp_ffi.a" -headers "$WORK/include" \
  -output "$WORK/ZippCoreFFI.xcframework" >/dev/null

# Nur austauschen, was sich geändert hat (sonst kompiliert Xcode jedes Mal alles neu)
mkdir -p "$GEN"
if ! cmp -s "$WORK/swift/zipp_ffi.swift" "$GEN/zipp_ffi.swift"; then
  cp "$WORK/swift/zipp_ffi.swift" "$GEN/zipp_ffi.swift"
fi
rsync -a --delete --checksum "$WORK/ZippCoreFFI.xcframework/" "$GEN/ZippCoreFFI.xcframework/"

echo "✓ Fertig: $GEN"
