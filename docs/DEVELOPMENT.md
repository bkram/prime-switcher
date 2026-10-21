# Developing Prime Switcher

This guide describes the implementation in this repository. For everyday operation, see the [user guide](USER_GUIDE.md). Before distributing a build, complete the [release checks](RELEASE_CHECKS.md).

## Set up and run

Use macOS, full Xcode with Swift 6.2 or newer, and SwiftLint **0.65.1** for the repository’s lint checks. The app targets macOS 14.2 and later. `Package.swift` defines the `PrimeSwitcher` executable; the source target retains the name `Input-to-Output-Monitor`.

Run commands from the repository root:

| Command | Result |
| --- | --- |
| `make build` | Debug executable |
| `make run` | Build and launch the executable |
| `make clean` | Clean Swift package build products |
| `make lint` | Strict SwiftLint checks |
| `make test` | Unit tests with code coverage |
| `make check` | Lint, debug build, unit tests with coverage, release build |
| `make dist` | Universal app bundle in `dist/Prime Switcher.app` |
| `make dmg` | Universal app and disk image in `dist/PrimeSwitcher.dmg` |

`make build` and `make run` default to 10 build jobs; override with `JOBS=4`, for example. The Makefile and packaging script honor `DEVELOPER_DIR` and fall back to `/Applications/Xcode.app/Contents/Developer` when only standalone Command Line Tools are selected.

## Package an app or disk image

```bash
./Scripts/make-app-bundle.sh          # Release bundle
./Scripts/make-app-bundle.sh debug    # Debug bundle
open "dist/Prime Switcher.app"
```

The script builds separate arm64 and x86_64 executables, combines them with `lipo`, verifies both architectures, and packages one app containing both routing sections. The bundle identifier is `com.mrk.primeswitcher`. The version is set in `Scripts/make-app-bundle.sh`; keep it aligned with release tags.

Packaging replaces the existing app bundle in `dist/`. It includes microphone and system audio capture usage descriptions and `Resources/AppIcon.icns` when present. Run the packaged app when verifying macOS permission behavior.

Signing defaults to ad-hoc. Set `SIGN_IDENTITY` to use an available signing identity; that path enables the hardened runtime. Neither packaging script submits the app for notarization.

```bash
./Scripts/make-dmg.sh
open dist/PrimeSwitcher.dmg
```

The DMG script rebuilds the release app, verifies its architectures, and replaces the disk image with a compressed image containing the app and an Applications shortcut. Signing, notarization, and first-launch acceptance must be verified separately before distribution.

For permission debugging, `make reset-permissions` attempts to reset Microphone and AudioCapture permissions for the bundle identifier. This changes local privacy grants; launch the packaged app and grant access again afterward. The target tolerates reset errors, so its completion message does not prove both resets succeeded.

## Find the code

| Source file | Responsibility |
| --- | --- |
| `InputToOutputMonitorApp.swift` | Shared controllers, app menus, window lifecycle, diagnostic launch mode |
| `ContentView.swift` | Section selection and shared window layout |
| `InputToOutputDevices.swift` | Device discovery and channel counts |
| `InterfaceRoutes.swift` | Interface route persistence, reconciliation, list, and editor |
| `InterfaceChannelSelection.swift` | Contiguous channel selection and channel maps |
| `InputToOutputMonitorEngine.swift` | Interface capture and playback through HAL audio units |
| `AppAudioProcesses.swift` | Application discovery and ownership of audio processes |
| `AudioRoutes.swift` | App route persistence, lifecycle, and destination selection |
| `AppAudioRouterEngine.swift` | Core Audio process taps, private aggregate devices, playback, and metering |
| `RouteRuntime.swift` | Runtime interfaces used by controllers and test doubles |
| `RoutesView.swift` | App route list, editor, selection, and status |
| `RouteComponents.swift` | Shared route controls and meters |

All source files above are in `Sources/Input-to-Output-Monitor/`.

Controllers reconcile saved enabled routes with available devices and applications. Devices are saved by UID, applications by bundle identifier. App routes rebuild when their process objects or destination device change. Failed app runtime configurations wait for an explicit retry or a changed configuration instead of retrying continuously.

Configuration uses UserDefaults keys `PrimeSwitcher.interfaceRoutes.v1`, `PrimeSwitcher.appRoutes.v1`, and `PrimeSwitcher.selectedSection`. UI channel numbers are one-based; stored channel indices and engine maps are zero-based. New routes created through either editor start disabled.

## Verify changes

Tests in `Tests/AudioRouterTests/` use fake runtimes and isolated UserDefaults suites. They cover route persistence, independent route lifecycles, disconnect/reconnect behavior, app relaunch, explicit retry after failure, channel suggestions, and interface channel maps. They do not capture audio, request permissions, or change system audio defaults.

The workflows in `.github/workflows/` select Xcode 26.3 and SwiftLint 0.65.1. CI runs on pull requests, main/master pushes, and manual invocation. It checks lint, debug and release builds, tests with coverage, and universal app packaging, then uploads coverage. No minimum coverage percentage is enforced.

The release workflow runs CI before packaging. A `v*` tag creates a GitHub release with the DMG; a manual run uploads the DMG as a workflow artifact. Local `make dmg` does not run `make check` first. Complete the [release checks](RELEASE_CHECKS.md) before shipping.

## Diagnose an app route

The packaged executable has a developer-only `--route-self-test` launch option. Each argument describes a route as `bundleID,outputUID,left,right`; channel numbers are one-based. Use an actual application bundle identifier and Core Audio device UID, rather than display names:

```sh
open -n -W "dist/Prime Switcher.app" --args --route-self-test \
  'APPLICATION_BUNDLE_ID,OUTPUT_DEVICE_UID,1,2'
cat /tmp/router-self-test.txt
```

Replace the uppercase placeholders before running. Start playback in the source app first. The test refreshes discovery, starts the requested routes, measures levels for about three seconds, writes startup results and peaks to `/tmp/router-self-test.txt`, and quits. It leaves the source application's normal output unmuted, so duplicated playback is possible.

Saved app routes are suppressed in this mode; saved interface routes can still start. Turn routes off and quit any other Prime Switcher instance before testing. The report detects startup and signal levels; it does not verify physical output, channel isolation, or normal muted routing. Run the manual release checks for those behaviors.

## Update icon assets

`Resources/AppIcon.png` is the source artwork. Run `./Scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`, then rebuild the app or DMG. The artwork’s generation prompts are preserved in [AppIcon.md](../Resources/AppIcon.md).
