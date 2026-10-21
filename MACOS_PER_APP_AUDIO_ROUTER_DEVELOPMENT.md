# Earlier macOS app-routing proposal

> Historical design proposal, written before the current Prime Switcher implementation.
> Use the [development guide](docs/DEVELOPMENT.md) for current build commands and architecture,
> the [user guide](docs/USER_GUIDE.md) for operation, and [release checks](docs/RELEASE_CHECKS.md)
> for validation. The proposal below is retained as design context, not an implementation checklist.

Prime Switcher now provides a SwiftUI window with app routes and interface routes on macOS 14.2 or later. Its executable is `PrimeSwitcher`, its bundle identifier is `com.mrk.primeswitcher`, and it stores routes in UserDefaults. The proposed `macroute` CLI, local IPC service, JSON settings file, and login item are not implemented. The diagnostic launch option in the current app is not a general routing CLI.

The remaining text preserves the original proposal, including its working name, milestones, and hypothetical commands.

---

## Original proposal

Status: Implementation specification
Updated: 2026-10-16
Working name: `macroute`
Language: Swift 6
Platform: macOS 15+ initially; Process Taps are available on macOS 14.2+

## 1. Project objective

Build a small, native macOS application that routes the audio **output** of
individual applications to chosen Core Audio output devices, while leaving
the global default output unchanged.

Example use cases:

- Firefox audio goes to `BlackHole 2ch`.
- A music player goes to a USB audio interface.
- Everything else continues to use the system default speakers.
- Routing can be controlled from a CLI and, later, an optional menu-bar UI.

The solution must use Apple's **public Core Audio APIs** without process
injection, a kernel extension, a custom HAL driver, root privileges, or SIP
changes. It must request the user-visible macOS **System Audio Recording**
permission. “Native” does not mean permission-free.

### Non-goals for the first release

- Redirecting another application's *microphone/input* selection.
- Providing a new virtual sound card; BlackHole remains a separate, optional
  output target if installed.
- Recording, storing, streaming, or analyzing captured program audio.
- A DAW, mixer, equalizer, DSP effects suite, or audio-volume booster.
- Circumventing DRM, protected content, or application-specific restrictions.
- AirPlay or network devices as guaranteed supported output targets.

## 2. Architecture and constraints

Apple's Process Taps API captures audio produced by selected Core Audio
process objects. A tap can mute the source application's ordinary playback.
A tap is **not** by itself an output device; a **private aggregate device**
combining the tap and a physical/virtual output is used for playback.

```text
                           Normal system default output
                           (unchanged for unrelated apps)
                                       ^
                                       |
Unrouted apps -------------------------+

Selected app, including its audio helper processes
    |
    v
Core Audio Process Tap (target processes; muted while routed)
    |
    v
Private HAL aggregate device
    - tap provides input stream(s)
    - chosen output device provides output stream(s)
    - chosen output device is clock master
    - tap drift compensation enabled
    |
    v
ONE AudioDeviceIOProc / AudioDeviceIOBlock
    - read tap input
    - write destination output
    - optional gain and metering later
    |
    v
USB DAC / built-in speakers / BlackHole 2ch
```

**Hard requirement:** Start with a **single aggregate device and one I/O
callback per route**. Do not implement capture into a ring buffer followed by
an independently clocked playback engine. Such a two-clock architecture needs
adaptive sample-rate conversion and is unnecessarily fragile, especially for
Bluetooth outputs.

A route must be a process-owned resource. The app or routing service must
remain running for audio to be redirected. Exiting the route owner destroys
the route; a saved preference alone does not keep routing active.

### Minimum operating system

- Apple documents Process Taps for **macOS 14.2+**.
- Set the project's **initial** deployment target to **macOS 15.0** to
  simplify validation and Swift 6 development.
- Lower to 14.2 only after explicit build and runtime validation.

## 3. Technical stack

| Concern | Recommended technology |
| --- | --- |
| Language | Swift 6 |
| Build | Swift Package Manager |
| Core Audio objects/devices | `CoreAudio`, HAL property APIs |
| Process taps | `CATapDescription`, `AudioHardwareCreateProcessTap` |
| Audio playback | Private HAL aggregate + `AudioDeviceIOProc` |
| Optional user interface | SwiftUI `MenuBarExtra` |
| Local CLI-to-app communication | Unix-domain socket or local XPC |
| Settings | Codable JSON in Application Support |
| Logging | `os.Logger` / unified logging |
| Tests | Swift Testing or XCTest |
| Distribution | Signed `.app` bundle; no installer required |

Start with **no external Swift package dependencies**. Avoid pulling in
audio libraries or a generic background service framework until a real need
is demonstrated.

## 4. Repository layout

```text
macroute/
├── Package.swift
├── README.md
├── DEVELOPMENT.md
├── Sources/
│   ├── MacRouteCore/
│   │   ├── AudioHAL.swift
│   │   ├── AudioDevices.swift
│   │   ├── AudioProcesses.swift
│   │   ├── ApplicationGrouping.swift
│   │   ├── AudioTap.swift
│   │   ├── AggregateDevice.swift
│   │   ├── RouteEngine.swift
│   │   ├── RouteManager.swift
│   │   ├── RouteSettings.swift
│   │   ├── RouteDiagnostics.swift
│   │   └── AudioRouteError.swift
│   ├── macroute/
│   │   └── main.swift
│   └── MacRouteApp/
│       ├── MacRouteApp.swift
│       ├── MenuBarView.swift
│       └── Resources/
├── Tests/
│   └── MacRouteCoreTests/
├── Packaging/
│   ├── Info.plist
│   ├── build-app.sh
│   └── entitlements.plist
└── scripts/
    └── smoke-test.sh
```

For the first milestone, implement only `MacRouteCore` and a foreground CLI
wrapped in a signed `.app` for reliable permission handling. Implement the
menu-bar owner and persistent CLI protocol after single-route audio works.

### `Package.swift` baseline

Use this as an **initial package manifest**, not a claim that the targets
already have working sources:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRoute",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacRouteCore", targets: ["MacRouteCore"]),
        .executable(name: "macroute", targets: ["macroute"]),
        .executable(name: "MacRouteApp", targets: ["MacRouteApp"])
    ],
    targets: [
        .target(name: "MacRouteCore"),
        .executableTarget(name: "macroute", dependencies: ["MacRouteCore"]),
        .executableTarget(name: "MacRouteApp", dependencies: ["MacRouteCore"]),
        .testTarget(
            name: "MacRouteCoreTests",
            dependencies: ["MacRouteCore"]
        )
    ]
)
```

Swift 6 concurrency checks must not be worked around globally. Keep Core
Audio HAL ownership isolated on a single control queue/actor and keep the
real-time callback independent of actor hops.

## 5. Discover audio devices

Use `AudioObjectGetPropertyDataSize` and `AudioObjectGetPropertyData` with
`kAudioHardwarePropertyDevices` to enumerate device object IDs.

For each device, expose:

- Device name (`kAudioObjectPropertyName`).
- Stable device UID (`kAudioDevicePropertyDeviceUID`).
- Whether it has output streams / output channels.
- Nominal sample rate and supported rates, when available.
- Current alive/online status (`kAudioDevicePropertyDeviceIsAlive`).
- Transport type when available (USB, built-in, Bluetooth, etc.).

**Do not persist `AudioObjectID`**: these are session-local identifiers and
may change after unplugging/replugging devices. Store **device UID** and
resolve it to the current HAL ID whenever starting a route.

For the first MVP, require a currently available, nonzero-output-channel
Core Audio device. Filter out input-only devices. A named output such as
`BlackHole 2ch` is a normal candidate if that driver is already installed.

## 6. Discover and group audio-producing processes

Core Audio process objects and operating-system PIDs are **not** identical.
A `CATapDescription` takes **Core Audio process object IDs**, not raw PIDs.

Relevant selectors:

- `kAudioHardwarePropertyProcessObjectList`: enumerates audio process objects.
- `kAudioProcessPropertyPID`: maps an audio process object to a PID.
- `kAudioProcessPropertyBundleID`: possible bundle identity.
- `kAudioProcessPropertyIsRunningOutput`: whether output I/O is active.
- `kAudioHardwarePropertyTranslatePIDToProcessObject`: PID lookup as needed.

A browser often emits audio from a helper, renderer, or XPC service instead
of its visible main PID. Selecting only `Firefox` or `Spotify`'s foreground
PID can result in **silence**, despite a correctly created tap.

Implement the following grouping logic:

1. Enumerate Core Audio audio process objects.
2. Resolve PID, bundle identifier, executable path, and display name.
3. Determine the *owning application* from the enclosing `.app` bundle.
4. Group helpers under the visible owning application.
5. Fall back conservatively if ownership cannot be established.
6. Exclude `macroute` itself from capture and list it separately for debug.
7. Watch changes and rebuild affected routes when helpers appear or exit.

Avoid using the parent PID as the sole grouping method: many helpers are
launched by `launchd`. The enclosing application bundle and stable bundle
identifier are usually stronger signals.

For the first milestone, offer `--raw` to list individual Core Audio process
objects. Only claim full app-level routing after helper grouping is tested.

## 7. Implement one route

### 7.1 Validate the target

Resolve the selected application to one or more valid Core Audio process
object IDs and the target output **UID** to a live HAL output device.
Reject empty/unresolved matches with actionable errors.

### 7.2 Create a private process tap

The documented Swift initializer for a stereo mixdown of selected process
objects is:

```swift
import CoreAudio

let description = CATapDescription(
    stereoMixdownOfProcesses: audioProcessObjectIDs
)
description.name = "MacRoute: selected application"
description.isPrivate = true
description.muteBehavior = .mutedWhenTapped

var tapID = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateProcessTap(description, &tapID)
guard status == noErr else {
    throw AudioRouteError.coreAudio(status)
}
```

This snippet illustrates **tap creation only**. It is not a complete audio
router, and `audioProcessObjectIDs` must already have been obtained from HAL.

Prefer testing `.mutedWhenTapped` first: Apple's defined behavior allows
original playback until an audio client reads from the tap, then mutes that
original route while tap reading continues. Compare with `.muted` under
error, disconnect, and stop conditions. Use whichever mode actually
provides the safest verified fallback; do not assume zero interruption.

### 7.3 Create a private aggregate device

Attach both (1) the chosen destination output and (2) the tap. Keep the
output as main clock source and enable tap drift compensation. A useful
configuration skeleton is:

```swift
let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "MacRoute Private Aggregate",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outputDeviceUID]
    ],
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapUIDKey: description.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true
        ]
    ]
]

var aggregateID = AudioObjectID(kAudioObjectUnknown)
let result = AudioHardwareCreateAggregateDevice(
    aggregateDescription as CFDictionary,
    &aggregateID
)
guard result == noErr else {
    throw AudioRouteError.coreAudio(result)
}
```

`aggregateUID` must be a new, locally generated unique identifier.
Before relying on `description.uuid`, verify the tap's actual UID using
`kAudioTapPropertyUID`. Treat the returned UID as authoritative if the HAL
assigns a different one. Confirm each configuration key against the SDK
being compiled and use Apple's sample as the API reference.

**Wait for** `kAudioDevicePropertyDeviceIsAlive` to become true before
starting I/O. Aggregate creation may return before it is ready; starting too
soon can produce zero buffers even when Core Audio reports success.

### 7.4 Attach one real-time I/O callback

Use `AudioDeviceCreateIOProcIDWithBlock` on the **aggregate device**. In
its callback, read the tap input from the aggregate and write that audio to
the output buffer(s) of the selected device. Start it using `AudioDeviceStart`.

This is deliberately **pseudocode**, because the exact `AudioBufferList`
layout and number of streams depend on the actual device:

```text
onAggregateIO(inputBuffers, outputBuffers):
    identify the tap input streams
    identify the selected output streams
    adapt channel mapping without allocating
    copy / convert each available frame to output
    fill unused output frames with zeroes
    update lock-free diagnostic counters
    return immediately
```

Do not assume the first input stream is the tap. Duplex USB interfaces
contribute their own microphone/line-in streams; identify tap streams after
accounting for hardware input streams. Test mono, stereo, non-interleaved,
and interleaved formats instead of casting every buffer to `Float32[2]`.

### 7.5 Real-time audio rules

Inside the HAL callback, **never**:

- Allocate memory, create Swift arrays, or format strings.
- Log to console, write a file, or call the UI.
- Perform network requests or socket I/O.
- Take a blocking lock, wait on a semaphore, or use an actor `await`.
- Ask HAL to enumerate audio devices or change properties.
- Perform sample-rate configuration or rebuild a route.

Allocate scratch space off the audio thread, pass read-only immutable
configuration safely, and use atomic counters for diagnostics. The callback
must handle a shutdown transition and always fully initialize its output
buffers. Keep processing at unity gain in the MVP.

If formats or clocks are incompatible, report an explicit route error rather
than playing audio at the wrong pitch. Using one aggregate and drift
compensation reduces the problem but does **not** excuse runtime validation.

### 7.6 Tear down cleanly

On normal route removal, exit, device loss, or an error:

1. Stop the aggregate IOProc using `AudioDeviceStop`.
2. Destroy it using `AudioDeviceDestroyIOProcID`.
3. Destroy the aggregate using `AudioHardwareDestroyAggregateDevice`.
4. Destroy the process tap using `AudioHardwareDestroyProcessTap`.
5. Release callback state and all property listeners as appropriate.
6. Mark the route inactive and surface the reason to the user.

Keep all `AudioObjectID`s and IOProc handles in a dedicated route owner.
Support idempotent cleanup after any intermediate construction failure.
Stop/destroy on a control thread, **never** inside the audio callback.

## 8. Routing state machine

Model route startup and teardown explicitly:

```text
INACTIVE
  -> RESOLVING_PROCESS
  -> RESOLVING_DEVICE
  -> CREATING_TAP
  -> CREATING_AGGREGATE
  -> WAITING_FOR_DEVICE_ALIVE
  -> STARTING_IO
  -> ACTIVE

Any setup error -> CLEANUP -> FAILED -> INACTIVE
ACTIVE + app exit -> CLEANUP -> WAITING_FOR_APP
ACTIVE + target unplug -> CLEANUP -> DEVICE_UNAVAILABLE
ACTIVE + reset/quit -> CLEANUP -> INACTIVE
```

Only display `ACTIVE` after I/O has started and the device is ready.
Nonzero audio samples are useful diagnostics but cannot be required for
active status because legitimate program silence is common.

A target device disappearing must **not** leave a muted application with no
playback. Destroy the tap quickly so the app can resume its original output,
and indicate degraded status. Do not silently switch the global default.

Add a watchdog for stalled I/O callbacks or invalid audio objects. A stream
of zeroes alone is not proof of failure; require corroborating evidence.

## 9. CLI design

These are **target commands to implement**, not claims that the binaries
exist yet:

```bash
# Inspect the system.
macroute devices
macroute apps
macroute apps --raw
macroute status

# MVP: foreground session; Ctrl-C should cleanly undo the route.
macroute route --app org.mozilla.firefox --device "BlackHole 2ch"

# Persistent mode: submit commands to the running, authorized MacRoute.app.
macroute set org.mozilla.firefox --device "BlackHole 2ch"
macroute set com.spotify.client --device "USB Audio DAC"
macroute reset org.mozilla.firefox
macroute reset --all
macroute status --json

# Troubleshooting.
macroute doctor
macroute devices --json
macroute apps --raw --json
```

Use exact **bundle ID** and device **UID** as canonical machine identifiers.
Allow display names as interactive aliases, but reject ambiguous matches.
Never assume an application's friendly name identifies just one process.

Suggested exit codes:

| Exit code | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Bad command or ambiguous name |
| 3 | App not running / not found |
| 4 | Output device unavailable |
| 5 | System-audio capture permission missing |
| 6 | Core Audio route setup failed |
| 7 | Background routing owner not running |

### CLI vs. application ownership

A single `macroute route ...` process may own one **foreground** route. It
must remain running while playback is redirected. `Ctrl-C` should trigger
best-effort cleanup; a forced `SIGKILL` cannot execute cleanup handlers.

For persistent `set` / `reset`, use **one signed `.app` as route owner**,
with the CLI acting as a **local control client**. Do not assume separate CLI
invocations can transfer live tap or aggregate ownership to each other.

A local IPC server must authenticate the connecting user's identity, allow
only same-user control, and expose no network listener by default. A
Unix-domain socket should live in a user-protected runtime directory
(`0700` parent directory, restrictive socket permissions). XPC is an
alternative if its connection and signing constraints fit the package.

## 10. Permissions, privacy, signing

Add this key to the actual **executing app's** `Info.plist`:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Route selected applications to audio devices you choose.</string>
```

- Apple requires **System Audio Recording** consent to use process taps.
- The user approves it in System Settings → Privacy & Security →
  Screen & System Audio Recording (wording varies by macOS version).
- Test from a proper, signed `.app` early rather than assuming a bare
  Terminal-launched SwiftPM executable will receive permission consistently.
- The signed route-owning process must be the process that creates the tap.
- Keep a stable bundle ID and preferably a stable signing identity so that
  development rebuilds do not repeatedly disrupt TCC permissions.
- Ad-hoc signing is possible for local experiments, but permission behavior
  across rebuilds can be inconvenient.
- Do not request microphone permission merely for output capture; add it
  only if a future feature actually uses microphone input.
- Do not attempt to bypass TCC or SIP. No administrator privilege required.
- Do not keep captured audio or upload telemetry. Make no network calls.

**Practical trap:** a tap can be created successfully yet deliver silent
buffers when capture permission is missing. `macroute doctor` must guide the
user through permission checks before diagnosing DSP bugs.

Protected content and some applications may resist capture. Report those
limitations; never add private-framework hooks or DRM bypass code.

## 11. Settings and persistence

Save desired routing preferences, not HAL object identifiers:

```json
{
  "version": 1,
  "routes": [
    {
      "appBundleID": "org.mozilla.firefox",
      "outputDeviceUID": "EXAMPLE-REPLACE-WITH-ACTUAL-DEVICE-UID",
      "enabled": true
    }
  ]
}
```

Suggested location:

```text
~/Library/Application Support/MacRoute/routes.json
```

Persist preferences atomically. Restore saved routes when the route-owning
app launches and when the selected application starts producing audio.
Do not automatically replace an unavailable output with an unrelated
speaker; show an explicit `DEVICE_UNAVAILABLE` status instead.

Use `SMAppService` for an **opt-in** login item later. Do not start at login
by default and do not require a privileged launch daemon.

## 12. Monitoring and recovery

Listen for relevant Core Audio property changes rather than busy-polling:

- Device list and device-alive changes.
- Default output changes where a route is scoped to that output.
- Device sample-rate or stream-layout changes.
- Process object creation/removal and audio helper restart.
- Route process termination and HAL errors.

Possible recovery policy:

- **Application helper restarts:** rebuild that application's tap with its
  currently valid audio process object IDs.
- **Output disconnects:** tear down the tap and aggregate; return to normal
  app output as safely as possible and show an offline route.
- **Device reconnects:** wait for an alive device and offer retry or apply
  the user's saved preference, depending on an explicit configuration flag.
- **Sample-rate changes:** rebuild safely off the callback thread.
- **Permission revoked:** stop capture, release the route, and show guidance.
- **Audio service reset:** re-enumerate all Core Audio object IDs.

Be conservative: a failed route must be more noticeable than a silently
misdirected output.

## 13. Tests and acceptance criteria

### Unit tests (no audio hardware)

- UID-based device lookup and ambiguous friendly-name resolution.
- Process grouping: main application, helpers, XPC services, and unknowns.
- Route state machine transitions and retry limits.
- Settings migration and atomic persistence.
- Cleanup idempotence on partially created routes.
- CLI parsing and error-to-exit-code mappings.

### Manual integration tests (actual macOS session)

| Scenario | Expected result |
| --- | --- |
| Firefox → USB DAC | Browser plays on DAC only |
| Firefox → BlackHole 2ch | BlackHole input receives browser audio |
| Firefox routed, other app unrouted | Other app stays on default output |
| Two apps to different devices | Routes remain isolated |
| Browser helper changes PID | Route rebinds or clearly reports failure |
| Destination unplugged | Route releases; app isn't left permanently muted |
| Destination reconnected | Configurable retry without restarting macOS |
| Permission denied/revoked | Clear error; no secret workaround |
| 44.1 ↔ 48 kHz change | No wrong-pitch playback; rebuild if necessary |
| Mono output | Channel mapping handles mono correctly |
| Duplex USB interface | Mic inputs aren't accidentally sent to output |
| `Ctrl-C` during foreground route | Routing resources are released |
| App quit/relaunch | Saved preference reapplies in persistent mode |
| macOS sleep/wake | Recover or report explicit failure |
| One hour playback | No memory/object leak or growing glitch rate |

Also test external speakers, Bluetooth, HDMI, AirPlay, and aggregate devices
separately. These should initially be labelled **experimental** unless
validated. Never advertise support simply because a device appears in HAL.

### Correctness checks

1. Global output device UID remains unchanged throughout routing.
2. No second copy of selected app audio is audible on original speakers.
3. Output is at normal pitch without persistent underruns or obvious drift.
4. Original app output resumes after routing is disabled.
5. A normal signed build prompts for required permission once as expected.
6. Shutdown removes all privately owned taps and aggregates.
7. CLI JSON stays machine-readable; logging does not corrupt stdout.
8. No special root, kext, driver, or SIP state is required.

## 14. Milestone-by-milestone implementation

### Milestone 0 — Establish the environment

- Create the Swift package and `.app` packaging target.
- Confirm Core Audio imports compile using `xcrun swift build`.
- Set stable app bundle ID, `Info.plist`, and code-signing strategy.
- Add unit-test and release-build scripts.

**Exit condition:** the signed app launches and the Core Audio API symbols
compile, without any attempt to route audio.

### Milestone 1 — Inventory

- Enumerate outputs by UID and readable name.
- Enumerate audio process objects and PIDs.
- Emit friendly list output and JSON.
- Include `doctor` for macOS version, signing, and permissions.

**Exit condition:** can reliably identify Firefox's active audio helper and
both BlackHole and a USB output by stable identifiers.

### Milestone 2 — One foreground route

- Create one process tap for an exact Core Audio process object.
- Build one private aggregate with output as clock master.
- Wait for aggregate readiness.
- Start one combined IOProc and copy audio to destination.
- Stop on Ctrl-C, cleaning up every resource.

**Exit condition:** live browser audio routes to one chosen USB output,
without altering the global default device.

### Milestone 3 — Robust process and device behavior

- Group helper processes under owning apps.
- Monitor device arrival/departure and process changes.
- Add state machine, diagnostics, permission-error messaging, and recovery.
- Test 44.1/48 kHz, USB duplex, and BlackHole.

**Exit condition:** common restarts, disconnects, and setup failures no
longer cause indefinite silence or leaked HAL objects.

### Milestone 4 — Persistent owner and CLI control

- Implement one signed app/service as owner of all route engines.
- Add secure, same-user local IPC.
- Add `set`, `reset`, `status`, and `--json`.
- Save preferences keyed by app bundle ID and device UID.

**Exit condition:** command exits while active routing continues under the
signed owner; multiple apps can have independent route preferences.

### Milestone 5 — Optional menu-bar app and packaging

- SwiftUI list of applications and device selection.
- Route status, device-offline indicator, and explicit reset action.
- Optional start-at-login with `SMAppService`.
- Universal binary, stable signature, release documentation.

**Exit condition:** native routing can be managed without using a terminal,
and all routing can be disabled immediately.

## 15. Suggested AI coding agent instructions

Give the following to a coding agent working in this repository:

> Implement the project defined in `DEVELOPMENT.md` in milestone order.
> Use only public macOS APIs and Swift 6. Build and test each milestone
> before beginning the next. Do not invent Core Audio selector names,
> method signatures, or capture entitlements; verify against installed SDK
> headers and Apple documentation. For routing, use one private aggregate
> device per route with the destination as clock master, tap drift
> compensation, and a single Core Audio I/O callback. Never call blocking
> APIs from the real-time callback. Treat signed `.app` ownership, audio
> permission, browser helpers, graceful cleanup, and device loss as
> first-class requirements. Do not implement audio recording, network
> access, a HAL driver, or private API injection. Keep a running list of
> compile/test results and any hardware-dependent tests not yet performed.

Don't ask the agent to build every feature in one enormous code-generation
pass. A HAL prototype with testable start/stop behavior is more valuable
than a complete UI surrounding a broken audio path.

## 16. Build commands

After sources and targets have been created:

```bash
# Validate the package and compile.
xcrun swift package dump-package >/dev/null
xcrun swift build --configuration debug

# Run tests that do not require a real tap or real audio hardware.
xcrun swift test

# Build the distributable .app after writing Packaging/build-app.sh.
./Packaging/build-app.sh

# Verify the resulting app's signature and privacy usage text.
codesign --verify --deep --strict --verbose=2 build/MacRoute.app
plutil -p build/MacRoute.app/Contents/Info.plist
```

`build/MacRoute.app` is a **target output location**, not an artifact supplied
with this guide. Packaging must produce and sign it.

For stable TCC identity, prefer an installed build with a consistent signing
identity and bundle identifier. Explicitly test a signed build launched via
Finder / `open`, not only a SwiftPM binary launched through a VS Code terminal.

## 17. Known limitations and open questions

- Process Taps are a **capture-and-replay route**, not an API that rewrites
  another application's selected output-device setting.
- Consent to System Audio Recording is unavoidable for this method.
- Latency depends on device I/O and the aggregate. Measure it; do not promise
  a particular millisecond figure without measurements.
- Browser audio may be produced by helpers that appear or disappear at
  runtime; routing by visible application PID alone is insufficient.
- Some protected playback and application-specific audio pathways may not
  be capturable; this is not an invitation to bypass protections.
- Bluetooth and AirPlay devices require independent hardware validation.
- A crash or device loss during muted routing can cause a temporary outage;
  the design can minimize but cannot guarantee gapless failover.
- Input device reassignment (microphone selection) is a separate feature
  outside this project's scope.
- Apple's official sample is a capture example, not a ready-made full
  multi-application audio router.

## 18. Authoritative references and prior art

### Apple documentation

1. [Capturing system audio with Core Audio taps][apple-taps]
2. [CATapDescription][apple-tap-description]
3. [CATapMuteBehavior][apple-tap-mute]
4. [AudioHardwareCreateProcessTap][apple-create-tap]
5. [AudioDeviceCreateIOProcIDWithBlock][apple-io-proc]
6. [NSAudioCaptureUsageDescription][apple-permission]
7. [kAudioHardwarePropertyProcessObjectList][apple-proc-list]

### Practical implementations worth studying

- [SoundRouter](https://github.com/dws741119/SoundRouter): Swift package
  with a per-app routing engine, process grouping, command line, and UI.
  Its MIT-licensed design is useful prior art; check its exact license and
  attribution obligations before reusing source files.
- [CoreAudioTapKit — How It Works][tapkit-how]:
  explains clocking, aggregate readiness, IOProc usage, and duplex-device
  stream mapping. Check licensing and API compatibility before code reuse.

**Implementation recommendation:** first inspect Apple's sample and the
CoreAudioTapKit one-callback design; use SoundRouter to understand app-helper
grouping and persistence. Independently validate any third-party claims
against your target macOS build and SDK.

[apple-taps]: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
[apple-tap-description]: https://developer.apple.com/documentation/coreaudio/catapdescription
[apple-tap-mute]: https://developer.apple.com/documentation/coreaudio/catapmutebehavior
[apple-create-tap]: https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
[apple-io-proc]: https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:)
[apple-permission]: https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
[apple-proc-list]: https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist
[tapkit-how]: https://github.com/CJStanfield/CoreAudioTapKit/blob/main/docs/how-it-works.md
