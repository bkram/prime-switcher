#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${1:-release}"
EXECUTABLE_NAME="Input-to-Output-Monitor"
APP_NAME="Input-to-Output Monitor"
BUNDLE_ID="com.mrk.inputtooutputmonitor"
VERSION="1.0.1"
MIN_MACOS="13.0"

BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
ICON_DEST_NAME="AppIcon"
ICON_DEST_PATH="$RESOURCES_DIR/$ICON_DEST_NAME.icns"

printf "==> Building (%s) for arm64 and x86_64\n" "$CONFIGURATION"
swift build -c "$CONFIGURATION" --arch arm64
swift build -c "$CONFIGURATION" --arch x86_64

# SwiftPM layout varies by toolchain; probe common locations.
ARM_PATH="$BUILD_DIR/arm64-apple-macosx/$CONFIGURATION/$EXECUTABLE_NAME"
X86_PATH="$BUILD_DIR/x86_64-apple-macosx/$CONFIGURATION/$EXECUTABLE_NAME"
EXECUTABLE_PATH=""
UNIVERSAL_PATH="$BUILD_DIR/universal/$CONFIGURATION/$EXECUTABLE_NAME"

if [[ -x "$ARM_PATH" && -x "$X86_PATH" ]]; then
  mkdir -p "$(dirname "$UNIVERSAL_PATH")"
  lipo -create -output "$UNIVERSAL_PATH" "$ARM_PATH" "$X86_PATH"
  EXECUTABLE_PATH="$UNIVERSAL_PATH"
fi

if [[ -z "$EXECUTABLE_PATH" ]]; then
  # Fallback: search a bit deeper.
  EXECUTABLE_PATH="$(find "$BUILD_DIR" -type f -name "$EXECUTABLE_NAME" -perm -111 | head -n 1 || true)"
fi

if [[ -z "$EXECUTABLE_PATH" || ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: could not find built executable: $EXECUTABLE_NAME" >&2
  echo "hint: run 'swift build -c $CONFIGURATION -v' and check .build/" >&2
  exit 1
fi

LIPO_INFO="$(lipo -info "$EXECUTABLE_PATH" 2>/dev/null || true)"
if [[ "$LIPO_INFO" != *"arm64"* || "$LIPO_INFO" != *"x86_64"* ]]; then
  echo "error: built executable is not universal (arm64 + x86_64)" >&2
  echo "info: $LIPO_INFO" >&2
  exit 1
fi

printf "==> Packaging app bundle at %s\n" "$APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

ICON_PLIST_SNIPPET=""
if [[ -f "$ICON_SOURCE" ]]; then
  printf "==> Including app icon: %s\n" "$ICON_SOURCE"
  cp "$ICON_SOURCE" "$ICON_DEST_PATH"
  ICON_PLIST_SNIPPET=$(cat <<ICON
  <key>CFBundleIconFile</key>
  <string>${ICON_DEST_NAME}</string>
ICON
)
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS}</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Input-to-Output Monitor needs microphone access to capture audio input and route it to your selected output device.</string>
${ICON_PLIST_SNIPPET}
</dict>
</plist>
PLIST

# Optional legacy metadata; harmless if present.
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

printf "==> Done\n"
printf "App bundle: %s\n" "$APP_DIR"
printf "Run with: open %q\n" "$APP_DIR"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  printf "==> Code signing (ad-hoc)\n"
  codesign --force --deep --sign - "$APP_DIR"
else
  printf "==> Code signing with identity: %s\n" "$SIGN_IDENTITY"
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
