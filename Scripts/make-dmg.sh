#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_BUNDLE="$ROOT_DIR/dist/Prime Switcher.app"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/PrimeSwitcher"
DMG_NAME="PrimeSwitcher"
DMG_PATH="$ROOT_DIR/dist/$DMG_NAME.dmg"
VOL_NAME="Prime Switcher"

STAGING_DIR="$ROOT_DIR/dist/.dmg-staging"

printf "==> Building Prime Switcher\n"
"$ROOT_DIR/Scripts/make-app-bundle.sh" release

if [[ ! -x "$APP_EXEC" ]]; then
  echo "error: expected executable at $APP_EXEC" >&2
  exit 1
fi

LIPO_INFO="$(lipo -info "$APP_EXEC" 2>/dev/null || true)"
if [[ "$LIPO_INFO" != *"arm64"* || "$LIPO_INFO" != *"x86_64"* ]]; then
  echo "error: app binary is not universal (arm64 + x86_64): $APP_EXEC" >&2
  exit 1
fi

printf "==> Staging DMG contents\n"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

printf "==> Creating DMG at %s\n" "$DMG_PATH"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

printf "==> Done\n"
printf "DMG: %s\n" "$DMG_PATH"
printf "Open with: open %q\n" "$DMG_PATH"
