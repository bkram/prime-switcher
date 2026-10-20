import CoreAudio
import Foundation
import Testing
@testable import Input_to_Output_Monitor

@MainActor
private final class FakeAppRuntime: AppRouteRuntime {
    var isRunning = false
    var failureMessage: String?
    var starts = 0
    var stops = 0
    func start(application: AppAudioSource, outputDevice: InputToOutputDevice, outputChannels: [Int]) {
        starts += 1
        isRunning = failureMessage == nil
    }
    func stop() { stops += 1; isRunning = false }
}

@MainActor
private final class FakeInterfaceRuntime: InterfaceRouteRuntime {
    var starts = 0
    var stops = 0
    func start(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
private final class Fixture {
    let suite = "AudioRouterTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let devices = InputToOutputDeviceManager(refreshImmediately: false)
    let processes = AppAudioProcessManager(refreshImmediately: false)
    var appRuntimes: [FakeAppRuntime] = []
    var interfaceRuntimes: [FakeInterfaceRuntime] = []
    var failure: String?

    init() { defaults = UserDefaults(suiteName: suite)! }
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    func apps() -> AudioRouteController {
        AudioRouteController(processManager: processes, deviceManager: devices,
                             defaults: defaults, observesHardware: false) { [self] in
            let runtime = FakeAppRuntime()
            runtime.failureMessage = failure
            appRuntimes.append(runtime)
            return runtime
        }
    }

    func interfaces() -> InterfaceRouteController {
        InterfaceRouteController(devices: devices, defaults: defaults, observesHardware: false) { [self] in
            let runtime = FakeInterfaceRuntime()
            interfaceRuntimes.append(runtime)
            return runtime
        }
    }
}

private func device(id: AudioDeviceID = 42, uid: String = "output", channels: Int = 6) -> InputToOutputDevice {
    InputToOutputDevice(deviceID: id, name: uid, uid: uid, hasInput: true, hasOutput: true,
                        inputChannelCount: 2, outputChannelCount: channels, transportType: 0)
}

private func application(id: AudioObjectID = 5, bundle: String = "test.player") -> AppAudioSource {
    AppAudioSource(processObjectIDs: [id], processIDs: [123], bundleID: bundle,
                   reportedBundleIDs: [bundle], name: bundle, isRunningOutput: true, icon: nil, menuIcon: nil)
}

private func appRoute(bundle: String = "test.player", enabled: Bool = true) -> AudioRoute {
    AudioRoute(bundleID: bundle, applicationName: bundle, deviceUID: "output", deviceName: "Output",
               channels: [2, 3], isEnabled: enabled)
}

private func interfaceRoute(enabled: Bool = true) -> InterfaceRoute {
    InterfaceRoute(inputUID: "input", inputName: "Input", outputUID: "output", outputName: "Output", isEnabled: enabled)
}

@Suite("Saved routes and hardware lifecycle")
@MainActor
struct RouteControllerTests {
    @Test func multipleAppRoutesPersistIncludingOffState() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        let first = appRoute()
        let second = appRoute(bundle: "another.player", enabled: false)
        controller.add(first)
        controller.add(second)
        controller.setEnabled(first.id, false)
        let restored = fixture.apps()
        #expect(restored.routes.count == 2)
        #expect(restored.routes.allSatisfy { !$0.isEnabled })
        #expect(restored.routes[0].channels == [2, 3])
        #expect(restored.routes[0].id == first.id)
        #expect(restored.runners.isEmpty)
    }

    @Test func appWaitsForApplicationThenDevice() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        let route = appRoute()
        controller.add(route)
        controller.reconcile(applications: [], devices: [device()])
        #expect(controller.states[route.id] == .waitingForApplication)
        controller.reconcile(applications: [application()], devices: [])
        #expect(controller.states[route.id] == .deviceMissing)
        #expect(fixture.appRuntimes.isEmpty)
    }

    @Test func unchangedAppRouteDoesNotRestart() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        let route = appRoute()
        controller.add(route)
        for _ in 0..<3 { controller.reconcile(applications: [application()], devices: [device()]) }
        #expect(fixture.appRuntimes.count == 1)
        #expect(controller.states[route.id] == .routing)
    }

    @Test func applicationRelaunchRebuildsTap() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        controller.add(appRoute())
        controller.reconcile(applications: [application()], devices: [device()])
        controller.reconcile(applications: [application(id: 9)], devices: [device()])
        #expect(fixture.appRuntimes.count == 2)
        #expect(fixture.appRuntimes[0].stops == 1)
    }

    @Test func disablingStopsAppAndPreservesDestination() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        let route = appRoute()
        controller.add(route)
        controller.reconcile(applications: [application()], devices: [device()])
        controller.setEnabled(route.id, false)
        controller.reconcile(applications: [application()], devices: [device()])
        #expect(fixture.appRuntimes[0].stops == 1)
        #expect(controller.states[route.id] == .off)
        #expect(controller.routes[0].deviceUID == route.deviceUID)
        #expect(controller.routes[0].channels == route.channels)
    }

    @Test func appDeviceDisconnectAndReconnect() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        controller.add(appRoute())
        controller.reconcile(applications: [application()], devices: [device()])
        controller.reconcile(applications: [application()], devices: [])
        #expect(fixture.appRuntimes[0].stops == 1)
        controller.reconcile(applications: [application()], devices: [device(id: 99)])
        #expect(fixture.appRuntimes.count == 2)
    }

    @Test func failedAppRouteWaitsForExplicitRetry() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.failure = "Permission denied"
        let controller = fixture.apps()
        let route = appRoute()
        controller.add(route)
        controller.reconcile(applications: [application()], devices: [device()])
        controller.reconcile(applications: [application()], devices: [device()])
        #expect(controller.states[route.id] == .failed("Permission denied"))
        #expect(fixture.appRuntimes.count == 1)
        fixture.failure = nil
        controller.setEnabled(route.id, true)
        controller.reconcile(applications: [application()], devices: [device()])
        #expect(controller.states[route.id] == .routing)
        #expect(fixture.appRuntimes.count == 2)
    }

    @Test func removingRunningAppStopsItAndPersistsRemoval() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        let route = appRoute()
        controller.add(route)
        controller.reconcile(applications: [application()], devices: [device()])
        controller.remove([route.id])
        controller.reconcile(applications: [application()], devices: [device()])
        #expect(fixture.appRuntimes[0].stops == 1)
        #expect(fixture.apps().routes.isEmpty)
    }

    @Test func channelSuggestionsAvoidSavedPairsAndSupportMono() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        controller.add(appRoute())
        #expect(controller.suggestedChannels(on: device(), for: UUID()) == [0, 1])
        #expect(controller.suggestedChannels(on: device(channels: 1), for: UUID()) == [0])
        #expect(controller.suggestedChannels(on: device(channels: 0), for: UUID()).isEmpty)
        #expect(appRoute().channelText == "Outputs 3–4")
    }

    @Test func sharedOutputsIgnoreDisabledRoutes() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        let first = appRoute()
        let second = appRoute(bundle: "another.player")
        controller.add(first)
        controller.add(second)
        #expect(controller.sharedOutputs(for: first) == [second.applicationName])
        controller.setEnabled(second.id, false)
        #expect(controller.sharedOutputs(for: first).isEmpty)
    }

    @Test func multipleInterfaceRoutesPersistAndCanBeEditedIndependently() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.interfaces()
        var first = interfaceRoute(enabled: false)
        let second = interfaceRoute(enabled: false)
        controller.save(first)
        controller.save(second)
        first.outputUID = "another-output"
        controller.save(first)
        #expect(fixture.interfaces().routes == [first, second])
        controller.remove(first)
        #expect(fixture.interfaces().routes == [second])
    }

    @Test func interfaceDisconnectReconnectAndOff() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.interfaces()
        let route = interfaceRoute()
        controller.save(route)
        controller.reconcile(inputs: [device(uid: "input")], outputs: [device()])
        controller.reconcile(inputs: [device(uid: "input")], outputs: [device()])
        #expect(fixture.interfaceRuntimes.count == 1)
        controller.reconcile(inputs: [], outputs: [device()])
        #expect(fixture.interfaceRuntimes[0].stops == 1)
        controller.reconcile(inputs: [device(id: 99, uid: "input")], outputs: [device()])
        #expect(fixture.interfaceRuntimes.count == 2)
        controller.setEnabled(route, false)
        #expect(fixture.interfaceRuntimes[1].stops == 1)
        #expect(!fixture.interfaces().routes[0].isEnabled)
    }

    @Test func turnAllAppRoutesOffKeepsEveryRoute() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        controller.add(appRoute())
        controller.add(appRoute(bundle: "second.player"))
        controller.turnAllOff()
        #expect(fixture.apps().routes.count == 2)
        #expect(fixture.apps().routes.allSatisfy { !$0.isEnabled })
    }

    @Test func simultaneousAppRoutesStopIndependently() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.apps()
        let first = appRoute()
        let second = appRoute(bundle: "second.player")
        let apps = [application(), application(id: 6, bundle: "second.player")]
        controller.add(first)
        controller.add(second)
        controller.reconcile(applications: apps, devices: [device()])
        #expect(fixture.appRuntimes.count == 2)
        controller.setEnabled(first.id, false)
        controller.reconcile(applications: apps, devices: [device()])
        #expect(fixture.appRuntimes[0].stops == 1)
        #expect(fixture.appRuntimes[1].isRunning)
        #expect(controller.states[second.id] == .routing)
        controller.stopAll()
        #expect(fixture.appRuntimes[1].stops == 1)
    }

    @Test func interfaceDeviceIDChangeRestartsSavedUID() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.interfaces()
        controller.save(interfaceRoute())
        controller.reconcile(inputs: [device(uid: "input")], outputs: [device()])
        controller.reconcile(inputs: [device(uid: "input")], outputs: [device(id: 100)])
        #expect(fixture.interfaceRuntimes.count == 2)
        #expect(fixture.interfaceRuntimes[0].stops == 1)
        controller.stopAll()
        #expect(fixture.interfaceRuntimes[1].stops == 1)
    }

    @Test func corruptConfigurationStartsEmpty() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        for key in ["PrimeSwitcher.appRoutes.v1", "PrimeSwitcher.interfaceRoutes.v1"] {
            fixture.defaults.set(Data("invalid JSON".utf8), forKey: key)
        }
        #expect(fixture.apps().routes.isEmpty)
        #expect(fixture.interfaces().routes.isEmpty)
    }
}
