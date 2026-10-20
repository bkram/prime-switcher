import SwiftUI
import Combine

struct InterfaceRoute: Identifiable, Codable, Equatable {
    var id = UUID()
    var inputUID: String
    var inputName: String
    var outputUID: String
    var outputName: String
    var isEnabled = false
}

@MainActor
final class InterfaceRouteController: ObservableObject {
    @Published private(set) var routes: [InterfaceRoute] = []
    @Published private(set) var engines: [UUID: InputToOutputMonitorEngine] = [:]
    let devices: InputToOutputDeviceManager
    private let defaults: UserDefaults
    private let makeRuntime: () -> any InterfaceRouteRuntime
    private var runtimes: [UUID: any InterfaceRouteRuntime] = [:]
    private var deviceKeys: [UUID: String] = [:]
    private var observations: Set<AnyCancellable> = []
    private static let key = "ApplicationAudioRouter.interfaceRoutes.v1"

    init(
        devices: InputToOutputDeviceManager,
        defaults: UserDefaults = .standard,
        observesHardware: Bool = true,
        makeRuntime: @escaping () -> any InterfaceRouteRuntime = { InputToOutputMonitorEngine() }
    ) {
        self.devices = devices
        self.defaults = defaults
        self.makeRuntime = makeRuntime
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([InterfaceRoute].self, from: data) { routes = saved }
        guard observesHardware else { return }
        Publishers.CombineLatest(devices.$inputDevices, devices.$outputDevices)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &observations)
    }

    func save(_ route: InterfaceRoute) {
        runtimes[route.id]?.stop()
        runtimes[route.id] = nil
        engines[route.id] = nil
        if let index = routes.firstIndex(where: { $0.id == route.id }) { routes[index] = route } else { routes.append(route) }
        persist()
        reconcile()
    }

    func setEnabled(_ route: InterfaceRoute, _ enabled: Bool) {
        var updated = route
        updated.isEnabled = enabled
        save(updated)
    }

    func remove(_ route: InterfaceRoute) {
        runtimes[route.id]?.stop()
        runtimes[route.id] = nil
        engines[route.id] = nil
        routes.removeAll { $0.id == route.id }
        persist()
    }

    func stopAll() { runtimes.values.forEach { $0.stop() } }

    private func persist() {
        if let data = try? JSONEncoder().encode(routes) { defaults.set(data, forKey: Self.key) }
    }

    func reconcile(inputs: [InputToOutputDevice]? = nil, outputs: [InputToOutputDevice]? = nil) {
        let inputs = inputs ?? devices.inputDevices
        let outputs = outputs ?? devices.outputDevices
        for route in routes {
            guard route.isEnabled,
                  let input = inputs.first(where: { $0.uid == route.inputUID }),
                  let output = outputs.first(where: { $0.uid == route.outputUID }) else {
                runtimes[route.id]?.stop()
                runtimes[route.id] = nil
                engines[route.id] = nil
                continue
            }
            let key = "\(input.deviceID):\(output.deviceID)"
            if runtimes[route.id] == nil || deviceKeys[route.id] != key {
                runtimes[route.id]?.stop()
                deviceKeys[route.id] = key
                let engine = makeRuntime()
                runtimes[route.id] = engine
                engines[route.id] = engine as? InputToOutputMonitorEngine
                engine.start(inputDeviceID: input.deviceID, outputDeviceID: output.deviceID)
            }
        }
    }
}

struct InterfaceRoutesView: View {
    @EnvironmentObject private var controller: InterfaceRouteController
    @State private var editor: InterfaceRoute?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RouteSectionHeader(
                title: "Interface → Interface",
                detail: "Forward audio from an input interface to an output.",
                refresh: { controller.devices.refreshDevices(selectDefaults: false) },
                add: { editor = InterfaceRoute(inputUID: "", inputName: "", outputUID: "", outputName: "") }
            )
            if controller.routes.isEmpty {
                ContentUnavailableView("No interface routes", systemImage: "cable.connector", description: Text("Add an input and output connection. Your choices are saved automatically."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.routes) { route in
                    RouteRowLayout(
                        source: route.inputName, destination: route.outputName,
                        detail: "Input audio",
                        isEnabled: Binding(get: { route.isEnabled }, set: { controller.setEnabled(route, $0) }),
                        edit: { editor = route }, remove: { controller.remove(route) },
                        icon: {
                        Image(systemName: "cable.connector").font(.title2).foregroundStyle(.secondary)
                    }, status: {
                        InterfaceRouteStatus(engine: controller.engines[route.id], enabled: route.isEnabled)
                    }, meter: {
                        if let engine = controller.engines[route.id] {
                            InterfaceSignalMeter(engine: engine)
                        } else { AudioSignalMeter(level: 0) }
                    })

                }
                .listStyle(.inset)
            }
            RouteFooter(text: "Off stops forwarding. Your route stays saved.", privacyPane: "Privacy_Microphone")
        }
        .sheet(item: $editor) { route in InterfaceRouteEditor(draft: route) }
    }
}

private struct InterfaceRouteStatus: View {
    @ObservedObject var engine: InputToOutputMonitorEngine
    init(engine: InputToOutputMonitorEngine?, enabled: Bool) {
        self.engine = engine ?? InputToOutputMonitorEngine()
        self.enabled = enabled
    }
    let enabled: Bool
    var body: some View {
        Group {
            if enabled && engine.isRunning {
                AudioPassingStatus(isPassing: max(engine.levelLeft, engine.levelRight) > 0.01)
            } else {
                Label(enabled ? (engine.statusMessage == "Idle" ? "Waiting for connected devices" : engine.statusMessage) : "Off", systemImage: enabled ? "clock" : "pause.circle")
                    .foregroundStyle(.secondary)
            }
        }.font(.caption)
    }
}

private struct InterfaceRouteEditor: View {
    @EnvironmentObject private var controller: InterfaceRouteController
    @Environment(\.dismiss) private var dismiss
    @State var draft: InterfaceRoute
    var body: some View {
        VStack(spacing: 0) {
            Text("Interface Route").font(.title2.bold()).padding(.top, 20)
            Form {
                Section {
                    Picker("Input Interface", selection: $draft.inputUID) {
                        Text(draft.inputUID.isEmpty ? "Choose an Input" : draft.inputName).tag(draft.inputUID)
                        ForEach(controller.devices.inputDevices.filter { $0.uid != draft.inputUID }) { Text($0.displayName).tag($0.uid) }
                    }
                    Picker("Output Interface", selection: $draft.outputUID) {
                        Text(draft.outputUID.isEmpty ? "Choose an Output" : draft.outputName).tag(draft.outputUID)
                        ForEach(controller.devices.outputDevices.filter { $0.uid != draft.outputUID }) { Text($0.displayName).tag($0.uid) }
                    }
                } footer: {
                    Text("New routes start off. Switch a route on to forward audio, or off to stop without losing its settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Route") { controller.save(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.inputUID.isEmpty || draft.outputUID.isEmpty)
            }.padding(16)
        }.frame(width: 480)
        .onChange(of: draft.inputUID) { draft.inputName = controller.devices.inputDevices.first { $0.uid == draft.inputUID }?.displayName ?? draft.inputName }
        .onChange(of: draft.outputUID) { draft.outputName = controller.devices.outputDevices.first { $0.uid == draft.outputUID }?.displayName ?? draft.outputName }
    }
}

private struct InterfaceSignalMeter: View {
    @ObservedObject var engine: InputToOutputMonitorEngine
    var body: some View {
        AudioSignalMeter(level: max(engine.levelLeft, engine.levelRight))
    }
}
