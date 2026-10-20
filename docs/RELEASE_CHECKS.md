# Release checks

## Automated checks

Run `make check` with full Xcode (Swift 6.2 or newer) and SwiftLint 0.65.1.
It runs strict lint, a debug build, Swift Testing tests with coverage, and a release build.
Tests use isolated UserDefaults suites and fake audio runtimes; they never request
permissions, capture audio, or change system audio defaults.

CI runs these checks on pull requests, pushes to main/master, and manual runs.
The DMG release workflow calls the same checks before packaging or publishing.
Coverage is uploaded as a CI artifact. There is no claim of full hardware coverage
or an enforced coverage percentage. SwiftLint's explicit legacy complexity/naming
exceptions are recorded in `.swiftlint.yml`; there is no violation baseline.

## Manual audio checks (required before shipping)

Record date, macOS, hardware, app build, and results for each release candidate.
A green meter confirms a detected signal, not the physical speaker's audibility.

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

## Remaining product/distribution work

- Interface routes support contiguous mono, stereo, and multichannel groups. Channel maps, persistence, and edits are unit-tested; confirm the desired physical channels on multichannel hardware before release.
- Signing and notarization require the owner's Apple Developer identity and release setup.
- Hosted CI results and coverage artifacts are available in [GitHub Actions](https://github.com/bkram/prime-switcher/actions/workflows/ci.yml). Check the current commit before each release.
- Main branch protection requires the GitHub Actions build/test/lint check, up-to-date pull requests, and resolved conversations. It also applies to admins and blocks force pushes and deletion.
