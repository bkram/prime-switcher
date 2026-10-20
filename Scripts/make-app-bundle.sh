#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Honor the toolchain selected by CI/xcode-select. Fall back to full Xcode
# only when the selected developer directory is the standalone command-line tools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED_DEVELOPER_DIR="$(xcode-select -p)"
  if [[ "$SELECTED_DEVELOPER_DIR" == *CommandLineTools* && -d /Applications/Xcode.app/Contents/Developer ]]; then
    SELECTED_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
fi

CONFIGURATION="${1:-release}"
EXECUTABLE_NAME="Input-to-Output-Monitor"
VERSION="1.1.0"
MIN_MACOS="14.2"

BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
ICON_DEST_NAME="AppIcon"

printf "==> Building (%s) for arm64 and x86_64\n" "$CONFIGURATION"
ARM_SCRATCH="$BUILD_DIR/package-arm64"
X86_SCRATCH="$BUILD_DIR/package-x86_64"
swift build -c "$CONFIGURATION" --triple arm64-apple-macosx --scratch-path "$ARM_SCRATCH"
swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx --scratch-path "$X86_SCRATCH"

# Ask SwiftPM for its product paths: Xcode versions use different layouts.
ARM_PRODUCTS="$(swift build -c "$CONFIGURATION" --triple arm64-apple-macosx --scratch-path "$ARM_SCRATCH" --show-bin-path)"
X86_PRODUCTS="$(swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx --scratch-path "$X86_SCRATCH" --show-bin-path)"
ARM_PATH="$ARM_PRODUCTS/$EXECUTABLE_NAME"
X86_PATH="$X86_PRODUCTS/$EXECUTABLE_NAME"
UNIVERSAL_PATH="$BUILD_DIR/universal/$CONFIGURATION/$EXECUTABLE_NAME"

if [[ ! -x "$ARM_PATH" || ! -x "$X86_PATH" ]]; then
  echo "error: could not find both architecture-specific executables" >&2
  echo "arm64: $ARM_PATH" >&2
  echo "x86_64: $X86_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$UNIVERSAL_PATH")"
lipo -create -output "$UNIVERSAL_PATH" "$ARM_PATH" "$X86_PATH"
EXECUTABLE_PATH="$UNIVERSAL_PATH"

LIPO_INFO="$(lipo -info "$EXECUTABLE_PATH" 2>/dev/null || true)"
if [[ "$LIPO_INFO" != *"arm64"* || "$LIPO_INFO" != *"x86_64"* ]]; then
  echo "error: built executable is not universal (arm64 + x86_64)" >&2
  echo "info: $LIPO_INFO" >&2
  exit 1
fi

# One binary serves both apps. ApplicationMode picks the tool from the bundle
# identifier, so each bundle only differs in name, identifier and privacy text.
# package_app <app name> <executable name> <bundle id> <usage key> <usage text>
package_app() {
  local app_name="$1" exec_name="$2" bundle_id="$3" usage_key="$4" usage_text="$5"
  local app_dir="$DIST_DIR/$app_name.app"
  local contents_dir="$app_dir/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"

  printf "==> Packaging app bundle at %s\n" "$app_dir"
  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$EXECUTABLE_PATH" "$macos_dir/$exec_name"
  chmod +x "$macos_dir/$exec_name"

  local icon_plist_snippet=""
  if [[ -f "$ICON_SOURCE" ]]; then
    printf "==> Including app icon: %s\n" "$ICON_SOURCE"
    cp "$ICON_SOURCE" "$resources_dir/$ICON_DEST_NAME.icns"
    icon_plist_snippet=$(cat <<ICON
  <key>CFBundleIconFile</key>
  <string>${ICON_DEST_NAME}</string>
ICON
)
  fi

  cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${exec_name}</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundleDisplayName</key>
  <string>${app_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS}</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Capture audio from your selected input interface.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Redirect audio from the applications you choose.</string>
${icon_plist_snippet}
</dict>
</plist>
PLIST

  # Optional legacy metadata; harmless if present.
  printf "APPL????" > "$contents_dir/PkgInfo"

  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf "==> Code signing (ad-hoc)\n"
    codesign --force --deep --sign - "$app_dir"
  else
    printf "==> Code signing with identity: %s\n" "$SIGN_IDENTITY"
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$app_dir"
  fi

  printf "App bundle: %s\n" "$app_dir"
  printf "Run with: open %q\n" "$app_dir"
}

SIGN_IDENTITY="${SIGN_IDENTITY:--}"

package_app "Input-to-Output Monitor" "Input-to-Output-Monitor" \
  "com.mrk.inputtooutputmonitor" "NSMicrophoneUsageDescription" \
  "Input-to-Output Monitor needs microphone access to capture audio input and route it to your selected output device."

package_app "Application Audio Router" "Application-Audio-Router" \
  "com.mrk.applicationaudiorouter" "NSAudioCaptureUsageDescription" \
  "Application Audio Router needs system audio access to route selected applications to audio devices you choose."

printf "==> Done\n"
