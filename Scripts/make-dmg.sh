#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Bundle name and executable name of every app in the DMG.
APPS=(
  "Input-to-Output Monitor:Input-to-Output-Monitor"
  "Application Audio Router:Application-Audio-Router"
)
DMG_NAME="InputToOutputMonitor"
DMG_PATH="$ROOT_DIR/dist/$DMG_NAME.dmg"
VOL_NAME="Input-to-Output Monitor"

STAGING_DIR="$ROOT_DIR/dist/.dmg-staging"

printf "==> Building app bundles\n"
"$ROOT_DIR/Scripts/make-app-bundle.sh" release

for entry in "${APPS[@]}"; do
  app_bundle="$ROOT_DIR/dist/${entry%%:*}.app"
  app_exec="$app_bundle/Contents/MacOS/${entry#*:}"

  if [[ ! -x "$app_exec" ]]; then
    echo "error: expected executable at $app_exec" >&2
    exit 1
  fi

  lipo_info="$(lipo -info "$app_exec" 2>/dev/null || true)"
  if [[ "$lipo_info" != *"arm64"* || "$lipo_info" != *"x86_64"* ]]; then
    echo "error: app binary is not universal (arm64 + x86_64): $app_exec" >&2
    echo "info: $lipo_info" >&2
    exit 1
  fi
done

printf "==> Staging DMG contents\n"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

for entry in "${APPS[@]}"; do
  cp -R "$ROOT_DIR/dist/${entry%%:*}.app" "$STAGING_DIR/"
done
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
