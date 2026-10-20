import AppKit
import Combine
import CoreAudio
import Foundation

/// One saved route: this application's audio goes to these channels of this
/// output device.
struct AudioRoute: Identifiable, Codable, Equatable {
    var id = UUID()
    var bundleID: String
    var applicationName: String
    var deviceUID: String
    var deviceName: String
    /// Zero-based output channels: a stereo pair or a single mono channel.
    var channels: [Int]
    var isEnabled = true

    var channelText: String {
        guard let first = channels.first else { return "No outputs" }
        return channels.count == 2 ? "Outputs \(first + 1)–\(channels[1] + 1)" : "Output \(first + 1)"
    }
}

enum RouteState: Equatable {
    case off
    case waitingForApplication
    case deviceMissing
    case routing
    case failed(String)
}

/// Owns the saved routes and keeps one RouteRunner per enabled route whose
/// application and device are present. Routes start when their application
/// opens, rebuild when it relaunches, and stop when it quits.
@MainActor
final class AudioRouteController: ObservableObject {
    @Published private(set) var routes: [AudioRoute] = []
    @Published private(set) var states: [UUID: RouteState] = [:]
    @Published private(set) var runners: [UUID: RouteRunner] = [:]
    /// Set by the Route menu; the routes window opens the new-route sheet.
    @Published var isPresentingNewRoute = false
    @Published var editingRouteID: UUID?

    let processManager: AppAudioProcessManager
    let deviceManager: InputToOutputDeviceManager

    /// What a runner was built for; a change means the route must restart.
    private struct RunKey: Equatable {
        let processObjectIDs: [AudioObjectID]
        let deviceID: AudioDeviceID
        let channels: [Int]
    }
    private let defaults: UserDefaults
    private let makeRuntime: () -> any AppRouteRuntime
    private var runtimes: [UUID: any AppRouteRuntime] = [:]
    private var runKeys: [UUID: RunKey] = [:]
    private var failedKeys: [UUID: RunKey] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var iconCache: [String: NSImage] = [:]

    private static let defaultsKey = "PrimeSwitcher.appRoutes.v1"

    init(
        processManager: AppAudioProcessManager,
        deviceManager: InputToOutputDeviceManager,
        defaults: UserDefaults = .standard,
        observesHardware: Bool = true,
        makeRuntime: @escaping () -> any AppRouteRuntime = { RouteRunner() }
    ) {
        self.processManager = processManager
        self.deviceManager = deviceManager
        self.defaults = defaults
        self.makeRuntime = makeRuntime
        routes = Self.loadRoutes(defaults: defaults)
        // The self-test runs its own route; saved routes would tap the same app.
        guard observesHardware, !CommandLine.arguments.contains("--route-self-test") else { return }
        observeChanges()
        installHardwareListeners()
    }

    // MARK: Editing

    func add(_ route: AudioRoute) {
        routes.append(route)
        save()
    }

    func update(_ route: AudioRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index] = route
        failedKeys[route.id] = nil
        save()
    }

    func remove(_ ids: Set<UUID>) {
        routes.removeAll { ids.contains($0.id) }
        save()
    }

    func setEnabled(_ id: UUID, _ isEnabled: Bool) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].isEnabled = isEnabled
        failedKeys[id] = nil
        save()
    }

    func turnAllOff() {
        for index in routes.indices { routes[index].isEnabled = false }
        save()
    }

    func stopAll() {
        for id in Array(runtimes.keys) { stopRunner(id) }
    }

    /// A new route prefilled with sensible choices: the first available
    /// application that is playing, the device the last route used, and the
    /// first stereo pair no other route on that device uses.
    func newRouteDraft() -> AudioRoute {
        let applications = availableApplications(excluding: nil)
        let application = applications.first(where: \.isRunningOutput) ?? applications.first
        let devices = deviceManager.outputDevices
        let device = routes.last.flatMap { last in devices.first(where: { $0.uid == last.deviceUID }) }
            ?? deviceManager.selectedOutputID.flatMap { id in devices.first(where: { $0.deviceID == id }) }
            ?? devices.first
        var draft = AudioRoute(
            bundleID: application?.bundleID ?? "",
            applicationName: application?.name ?? "",
            deviceUID: device?.uid ?? "",
            deviceName: device?.displayName ?? "",
            channels: [],
            isEnabled: false
        )
        if let device { draft.channels = suggestedChannels(on: device, for: draft.id) }
        return draft
    }

    func suggestedChannels(on device: InputToOutputDevice, for routeID: UUID) -> [Int] {
        let used = Set(routes.filter { $0.id != routeID && $0.deviceUID == device.uid }.flatMap(\.channels))
        let pairs = stride(from: 0, to: device.outputChannelCount - 1, by: 2).map { [$0, $0 + 1] }
        if let free = pairs.first(where: { used.isDisjoint(with: $0) }) { return free }
        if let pair = pairs.first { return pair }
        return device.outputChannelCount > 0 ? [0] : []
    }

    /// Applications a route may use: running ones not already routed elsewhere.
    func availableApplications(excluding routeID: UUID?) -> [AppAudioSource] {
        let taken = Set(routes.filter { $0.id != routeID }.map(\.bundleID))
        return processManager.applications.filter { !taken.contains($0.bundleID) }
    }

    /// Names of other enabled routes that send to any of the same outputs.
    func sharedOutputs(for route: AudioRoute) -> [String] {
        routes.filter {
            $0.id != route.id && $0.isEnabled && $0.deviceUID == route.deviceUID
                && !Set($0.channels).isDisjoint(with: route.channels)
        }.map(\.applicationName)
    }

    func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        let icon = processManager.applications.first(where: { $0.bundleID == bundleID })?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        if let icon { iconCache[bundleID] = icon }
        return icon
    }

    func refresh() {
        processManager.refresh()
        deviceManager.refreshDevices(selectDefaults: false)
    }

    // MARK: Keeping runners in step

    private func observeChanges() {
        Publishers.CombineLatest3(processManager.$applications, deviceManager.$outputDevices, $routes)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
    }

    func reconcile(applications: [AppAudioSource]? = nil, devices: [InputToOutputDevice]? = nil) {
        let applications = applications ?? processManager.applications
        let devices = devices ?? deviceManager.outputDevices
        migrateHelperRoutes()
        var newStates: [UUID: RouteState] = [:]
        for route in routes {
            newStates[route.id] = reconcile(route, applications: applications, devices: devices)
        }
        for id in Array(runtimes.keys) where !routes.contains(where: { $0.id == id }) {
            stopRunner(id)
        }
        states = newStates
    }

    /// Routes saved under a helper's own identifier, such as
    /// com.google.Chrome.helper, move to the application that owns the helper.
    private func migrateHelperRoutes() {
        var changed = false
        for index in routes.indices {
            let route = routes[index]
            guard !processManager.applications.contains(where: { $0.bundleID == route.bundleID }),
                  let owner = processManager.applications.first(where: { $0.reportedBundleIDs.contains(route.bundleID) }),
                  !routes.contains(where: { $0.id != route.id && $0.bundleID == owner.bundleID }) else { continue }
            routes[index].bundleID = owner.bundleID
            routes[index].applicationName = owner.name
            changed = true
        }
        if changed { save() }
    }

    private func reconcile(_ route: AudioRoute, applications: [AppAudioSource], devices: [InputToOutputDevice]) -> RouteState {
        guard route.isEnabled else {
            stopRunner(route.id)
            return .off
        }
        guard let application = applications.first(where: { $0.bundleID == route.bundleID }) else {
            stopRunner(route.id)
            return .waitingForApplication
        }
        guard let device = devices.first(where: { $0.uid == route.deviceUID }) else {
            stopRunner(route.id)
            return .deviceMissing
        }

        let key = RunKey(processObjectIDs: application.processObjectIDs, deviceID: device.deviceID, channels: route.channels)
        if runKeys[route.id] == key, runtimes[route.id]?.isRunning == true {
            return .routing
        }
        if failedKeys[route.id] == key, case .failed(let message) = states[route.id] {
            // Do not retry a failure until something about the route changes.
            return .failed(message)
        }

        stopRunner(route.id)
        let runner = makeRuntime()
        runner.start(application: application, outputDevice: device, outputChannels: route.channels)
        guard runner.isRunning else {
            failedKeys[route.id] = key
            return .failed(runner.failureMessage ?? "The route could not start.")
        }
        runtimes[route.id] = runner
        runners[route.id] = runner as? RouteRunner
        runKeys[route.id] = key
        failedKeys[route.id] = nil
        return .routing
    }

    private func stopRunner(_ id: UUID) {
        runtimes[id]?.stop()
        runtimes[id] = nil
        runners[id] = nil
        runKeys[id] = nil
    }

    /// Core Audio adds and removes process objects as applications start and
    /// stop using audio, and devices as they are plugged in.
    private func installHardwareListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if selector == kAudioHardwarePropertyDevices {
                        self.deviceManager.refreshDevices(selectDefaults: false)
                    } else {
                        self.processManager.refresh()
                    }
                }
            }
        }
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(routes) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func loadRoutes(defaults: UserDefaults) -> [AudioRoute] {
        guard let data = defaults.data(forKey: defaultsKey),
              let routes = try? JSONDecoder().decode([AudioRoute].self, from: data) else {
            return []
        }
        return routes
    }
}
