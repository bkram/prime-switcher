#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

EMOJI="${1:-🎧}"
OUT_ICNS="$ROOT_DIR/Resources/AppIcon.icns"

WORK_DIR="$ROOT_DIR/dist/.icon-work"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
BASE_PNG="$WORK_DIR/base-1024.png"

rm -rf "$WORK_DIR"
mkdir -p "$ICONSET_DIR"

# Render a 1024x1024 emoji PNG using AppKit.
swift - "$EMOJI" "$BASE_PNG" <<'SWIFT'
import AppKit
import Foundation

let emoji = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "🎧"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
guard !outPath.isEmpty else {
  fputs("Missing output path argument\\n", stderr)
  exit(2)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let fontSize: CGFloat = 860
let font = NSFont(name: "Apple Color Emoji", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
let attrs: [NSAttributedString.Key: Any] = [
  .font: font,
  .foregroundColor: NSColor.labelColor
]

let string = NSAttributedString(string: emoji, attributes: attrs)
let strSize = string.size()
let rect = NSRect(
  x: (size.width - strSize.width) / 2,
  y: (size.height - strSize.height) / 2 - 30,
  width: strSize.width,
  height: strSize.height
)
string.draw(in: rect)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
  fputs("Failed to render emoji image\n", stderr)
  exit(1)
}

try png.write(to: URL(fileURLWithPath: outPath))
SWIFT

# Helper to create a pair of iconset images.
make_icon() {
  local size="$1"
  local pixel="$2"
  sips -z "$pixel" "$pixel" "$BASE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
}

make_icon 16 16
make_icon 16 32
make_icon 32 32
make_icon 32 64
make_icon 128 128
make_icon 128 256
make_icon 256 256
make_icon 256 512
make_icon 512 512
make_icon 512 1024

iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

echo "Created: $OUT_ICNS"
