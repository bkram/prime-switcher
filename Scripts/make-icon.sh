#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
SOURCE_PNG="${1:-$ROOT_DIR/Resources/AppIcon.png}"
OUT_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
ICONSET_DIR="$ROOT_DIR/dist/.icon-work/AppIcon.iconset"
if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "Missing icon source: $SOURCE_PNG" >&2
  exit 1
fi
mkdir -p "$ICONSET_DIR"
# Preserve distinct standard and Retina representations.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"
echo "Created: $OUT_ICNS"
