# Releasing Prime Switcher

Use this checklist for each release candidate. Build instructions are in the
[development guide](DEVELOPMENT.md); operating instructions are in the
[user guide](USER_GUIDE.md).

## Identify the candidate

Create a record for each candidate before testing. Results from another build do not establish that this candidate passes.

| Field | Value to record |
| --- | --- |
| Test date | Date of this verification |
| Build | Commit SHA, packaged version, and any uncommitted changes |
| System | macOS version and Mac model/architecture |
| Audio setup | Device models, drivers, sample rates, and channel connections |
| Artifact | App/DMG filename, signing identity, and notarization status |
| Results | Pass/fail/pending for each check, with observations |

## Run automated checks

Run `make check` with full Xcode (Swift 6.2 or newer) and SwiftLint 0.65.1.
It runs strict lint, a debug build, Swift Testing tests with coverage, and a release build.
Tests use isolated UserDefaults suites and fake audio runtimes; they never request
permissions, capture audio, or change system audio defaults.

CI runs these checks on pull requests, pushes to main/master, and manual runs.
CI also smoke-tests universal app packaging. The DMG release workflow calls CI
before packaging or publishing; local `make dmg` does not run these checks.
Coverage is uploaded as a CI artifact. There is no claim of full hardware coverage
or an enforced coverage percentage. SwiftLint's explicit legacy complexity/naming
exceptions are recorded in `.swiftlint.yml`; there is no violation baseline.

## Verify audio on the candidate

Check each scenario below on the actual packaged candidate and record the outcome:

- One app route: playback reaches the selected output, pauses produce a quiet meter, and switching off restores normal app playback.
- Two app routes: both destinations are audible, and disabling one leaves the other active.
- Two interface routes: each input reaches its selected physical channels independently.
- Device disconnect/reconnect: the route stops while absent and resumes on the saved device when available.
- Source app quit/relaunch: the route waits and rebuilds for the new audio processes.
- Permission denied/granted: the error is clear and an explicit off/on retry succeeds after access is granted.
- Saved state: enabled and disabled routes, channel selections, and the selected section survive relaunch.
- Mono/stereo app outputs and larger interface groups: audio reaches exactly the intended channels.

For app routing, also confirm the system default output remains unchanged and unrelated apps retain their normal output. Record any unsupported device formats rather than treating device discovery as a pass.

## Historical audio observations

Record date, macOS, hardware, app build, and results for each release candidate.
A green meter confirms a detected signal, not the physical speaker's audibility.

The results below are historical observations from 2026-10-20, not verification
of every subsequent build. They do not record a complete build identifier, OS
version, or hardware inventory; rerun them and record those details before shipping.

| Scenario | Expected result | Current result |
| --- | --- | --- |
| Cog playing, route on | Audio on selected output; meter moves; Audio passing | Passed 2026-10-20: live meter and Audio passing observed; user confirmed audio on MacBook Pro Speakers |
| Cog pause/resume | Meter goes quiet and Waiting for audio appears; Audio passing returns on resume | Passed 2026-10-20 on latest tested preview build |
| Cog route off | Normal Cog output returns; saved destination remains | Passed 2026-10-20: Off with destination/channels retained; user confirmed normal output returned |
| Two app routes at once | Both outputs audible; disabling one leaves the other active | Pending on hardware; lifecycle unit-tested |
| Two interface routes at once | Each input reaches its output independently | Passed signal check 2026-10-20: Cog on BlackHole 3–4, four-channel map 3–6 to 9–12, second route 9–10 to speakers; both live meters receive signal |
| Input/output disconnected and reconnected | Stop while absent; resume saved UID when reconnected | Pending on hardware; lifecycle unit-tested |
| App quits and relaunches | Wait, then rebuild route for new process objects | Pending on hardware; lifecycle unit-tested |
| Permission denied, then granted | Clear error; explicit retry succeeds | Pending on macOS; failed-runtime retry unit-tested |
| Relaunch with saved on/off routes | Configuration and switch states restored | Passed 2026-10-20 for saved off-state and selected section; enabled-state configuration unit-tested |
| Mono and stereo app channels | Audio reaches exactly the selected channels | Pending on multichannel hardware |

## Verify packaging and app lifecycle

For each release candidate:

- Launch the packaged app and verify both routing sections under its own permission identity.
- Close the main window while routing and confirm audio continues; reopen it with ⌘0.
- Quit with ⌘Q and confirm routing stops; relaunch and check saved enabled routes resume.
- Use **Routes → Turn Off All Routes** and confirm both lists are disabled and stay off after relaunch.
- Verify the packaged version, icon, and arm64/x86_64 architectures.
- Mount the DMG, copy the app to Applications, and verify first launch on another Mac.
- Record the signing and notarization status of the actual artifact being distributed.

## Resolve distribution requirements

- Interface routes support contiguous mono, stereo, and multichannel groups. Channel maps, persistence, and edits are unit-tested; confirm the desired physical channels on multichannel hardware before release.
- Signing and notarization require the owner's Apple Developer identity and release setup.
- Hosted CI results and coverage artifacts are available in [GitHub Actions](https://github.com/bkram/prime-switcher/actions/workflows/ci.yml). Check the current commit before each release.
- Verify repository branch protection and required checks in GitHub before release; these settings are managed outside this repository.

## Local 1.1.0 candidate checks — 2026-10-21

Checked on an arm64 Mac running macOS 27.0.1 (26A434), using the source changes accompanying this record:

| Check | Result |
| --- | --- |
| Strict SwiftLint 0.65.1 | Passed; no violations |
| Debug build | Passed |
| Unit tests with coverage | Passed; 22 tests in two suites |
| Release build | Passed |
| Universal app and DMG build | Passed |
| Executable architectures | Confirmed arm64 and x86_64 |
| Packaged version / minimum macOS | 1.1.0 / 14.2 |
| App signature verification | Passed; ad-hoc signature |
| DMG integrity | Passed checksum verification |
| Notarization | Not performed |
| Hardware and first-launch checks | Pending; historical results above are not candidate verification |

GitHub CI must also pass for the final pushed commit. The local artifact is `dist/PrimeSwitcher.dmg`; generated artifacts are not committed.
