#!/usr/bin/env bash
# Baut ZIPP.app im Release-Modus (Universal: Apple Silicon + Intel).
#
# Aufruf:  scripts/build-app.sh [Version] [Build-Nummer]
# Ergebnis: build/Release/ZIPP.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
OUT="$ROOT/build/Release"

command -v xcodegen >/dev/null || { echo "error: xcodegen fehlt (brew install xcodegen)" >&2; exit 1; }

echo "▸ Rust-Kern (universal)"
"$ROOT/scripts/build-core.sh" release

echo "▸ Xcode-Projekt erzeugen"
(cd "$ROOT/app" && xcodegen generate --quiet)

ARGS=()
[[ -n "$VERSION" ]] && ARGS+=("MARKETING_VERSION=$VERSION")
[[ -n "$BUILD_NUMBER" ]] && ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")

echo "▸ App bauen (Release, universal)"
xcodebuild \
  -project "$ROOT/app/Zipp.xcodeproj" \
  -scheme Zipp \
  -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  -destination "generic/platform=macOS" \
  ONLY_ACTIVE_ARCH=NO \
  "${ARGS[@]}" \
  build | { command -v xcbeautify >/dev/null && xcbeautify || grep -E "error:|warning:|BUILD" ; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$ROOT/build/DerivedData/Build/Products/Release/ZIPP.app" "$OUT/"
echo "✓ $OUT/ZIPP.app ($(lipo -archs "$OUT/ZIPP.app/Contents/MacOS/ZIPP"))"
