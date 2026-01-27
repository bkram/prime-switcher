# Input-to-Output Monitor (macOS)

A minimal macOS SwiftUI app that opens an audio input device and plays it back on a chosen output device using CoreAudio HAL audio units.

## Run

From this directory:
an
```bash
swift run
```

Notes:
- You may need to grant microphone access to your terminal (System Settings -> Privacy & Security -> Microphone).
- Some device pairs may fail if the output device does not support the input device's sample rate and channel count.

## App Bundle (Distribution)

Build a distributable `.app` bundle:

```bash
./Scripts/make-app-bundle.sh
```

The bundle will be created at:
- `dist/Input-to-Output Monitor.app`

Run it with:

```bash
open "dist/Input-to-Output Monitor.app"
```

## DMG Package (Unsigned)

Create a simple unsigned DMG for distribution:

```bash
./Scripts/make-dmg.sh
open dist/InputToOutputMonitor.dmg
```

Notes:
- This DMG is unsigned and not notarized.
- On another Mac, users may need to right-click the app and choose **Open** the first time.

## App Icon

The bundler will include an icon automatically if you place:
- `Resources/AppIcon.icns`

Quick macOS-native workflow:
1. Create a square 1024x1024 PNG (e.g., headphones artwork).
2. Open it in Preview and export as multiple PNG sizes if desired.
3. Use `iconutil` with an iconset folder to produce `AppIcon.icns`, then place it at `Resources/AppIcon.icns`.
4. Rebuild the app bundle or DMG.

## Key files

- `Package.swift`
- `Sources/Input-to-Output-Monitor/InputToOutputDevices.swift`
- `Sources/Input-to-Output-Monitor/InputToOutputMonitorEngine.swift`
- `Sources/Input-to-Output-Monitor/ContentView.swift`
- `Sources/Input-to-Output-Monitor/InputToOutputMonitorApp.swift`
- `Scripts/make-app-bundle.sh`
- `Scripts/make-dmg.sh`
- `Resources/AppIcon.icns`
