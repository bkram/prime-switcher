import AppKit
import CoreAudio
import SwiftUI

/// The router window: a list of routes in the style of Login Items in
/// System Settings.
struct RoutesView: View {
    @EnvironmentObject private var controller: AudioRouteController
    @State private var selection: Set<UUID> = []
    @State private var editor: RouteEditorItem?

    var body: some View {
        VStack(spacing: 0) {
            RouteSectionHeader(
                title: "App → Interface",
                detail: "Send an app’s audio to an output interface and channels.",
                refresh: { controller.refresh() }, add: { presentNewRoute() }
            )
            if controller.routes.isEmpty {
                ContentUnavailableView {
                    Label("No app routes", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("A route sends one application's audio to the outputs you choose, such as Chrome to outputs 3–4 of BlackHole 16ch.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(controller.routes) { route in
                        RouteRow(route: route)
                            .tag(route.id)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenu(for: ids)
                } primaryAction: { ids in
                    edit(ids.first)
                }
                .onDeleteCommand { removeSelection() }
            }

            RouteFooter(text: "Off restores the app’s normal output. Your route stays saved.", privacyPane: "Privacy_AudioCapture")
        }
        .sheet(item: $editor) { item in
            RouteEditor(draft: item.route, isNew: item.isNew)
        }
        .onAppear {
            if controller.isPresentingNewRoute {
                controller.isPresentingNewRoute = false
                presentNewRoute()
            }
        }
        .onChange(of: controller.editingRouteID) {
            if let id = controller.editingRouteID {
                edit(id)
                controller.editingRouteID = nil
            }
        }
        .onChange(of: controller.isPresentingNewRoute) {
            if controller.isPresentingNewRoute {
                controller.isPresentingNewRoute = false
                presentNewRoute()
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first, let route = controller.routes.first(where: { $0.id == id }) {
            Button("Edit Route…") { edit(id) }
            Button(route.isEnabled ? "Turn Off" : "Turn On") {
                controller.setEnabled(id, !route.isEnabled)
            }
            Divider()
        }
        if !ids.isEmpty {
            Button(ids.count == 1 ? "Remove Route" : "Remove \(ids.count) Routes", role: .destructive) {
                controller.remove(ids)
                selection.subtract(ids)
            }
        }
    }

    private func presentNewRoute() {
        editor = RouteEditorItem(route: controller.newRouteDraft(), isNew: true)
    }

    private func edit(_ id: UUID?) {
        guard let id, let route = controller.routes.first(where: { $0.id == id }) else { return }
        editor = RouteEditorItem(route: route, isNew: false)
    }

    private func removeSelection() {
        guard !selection.isEmpty else { return }
        controller.remove(selection)
        selection.removeAll()
    }
}

private struct RouteEditorItem: Identifiable {
    let route: AudioRoute
    let isNew: Bool
    var id: UUID { route.id }
}

// MARK: - Row

private struct RouteRow: View {
    @EnvironmentObject private var controller: AudioRouteController
    let route: AudioRoute

    var body: some View {
        RouteRowLayout(
            source: route.applicationName, destination: route.deviceName,
            detail: route.channelText,
            isEnabled: Binding(get: { route.isEnabled }, set: { controller.setEnabled(route.id, $0) }),
            edit: { controller.editingRouteID = route.id },
            remove: { controller.remove([route.id]) },
            icon: {
            appIcon
        }, status: {
            RouteStatusText(route: route, state: controller.states[route.id] ?? .off, runner: controller.runners[route.id])
        }, meter: {
            if let runner = controller.runners[route.id] {
                RouteMeter(monitor: runner.levelMonitor)
            } else {
                AudioSignalMeter(level: 0)
            }
        })
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = controller.icon(for: route.bundleID) {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var deviceSymbol: String {
        controller.deviceManager.outputDevices.first(where: { $0.uid == route.deviceUID })?.symbolName ?? "hifispeaker"
    }
}

private struct RouteStatusText: View {
    let route: AudioRoute
    let state: RouteState
    let runner: RouteRunner?

    var body: some View {
        Group {
            if let runner {
                LiveStatus(route: route, monitor: runner.levelMonitor)
            } else {
                Label(text, systemImage: symbol)
                    .foregroundStyle(tint)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .help(helpText)
    }

    private var text: String {
        switch state {
        case .off: "Off"
        case .waitingForApplication: "Waiting for \(route.applicationName) to open"
        case .deviceMissing: "\(route.deviceName) is not connected"
        case .routing: "Routing"
        case .failed(let message): message
        }
    }

    private var symbol: String {
        switch state {
        case .off: "pause.circle"
        case .waitingForApplication: "clock"
        case .deviceMissing, .failed: "exclamationmark.triangle.fill"
        case .routing: "waveform"
        }
    }

    private var tint: Color {
        switch state {
        case .deviceMissing, .failed: .orange
        default: .secondary
        }
    }

    private var helpText: String {
        if case .failed(let message) = state { return message }
        return text
    }
}

/// Status of a running route; watches the meter so it can say when the
/// route carries only silence.
private struct LiveStatus: View {
    let route: AudioRoute
    @ObservedObject var monitor: RouteLevelMonitor

    var body: some View {
        AudioPassingStatus(isPassing: monitor.history.suffix(10).contains { $0 > 0.01 })
    }
}

/// A small level trace for one row.
private struct RouteMeter: View {
    @ObservedObject var monitor: RouteLevelMonitor
    var body: some View {
        AudioSignalMeter(level: monitor.history.last ?? 0)
    }
}

// MARK: - Editor

private struct RouteEditor: View {
    @EnvironmentObject private var controller: AudioRouteController
    @Environment(\.dismiss) private var dismiss
    @State var draft: AudioRoute
    let isNew: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New App Route" : "Edit App Route").font(.title2.bold()).padding(.top, 20)
            Form {
                Section {
                    Picker("Application", selection: $draft.bundleID) {
                        if draft.bundleID.isEmpty {
                            Text("Choose an Application").tag("")
                        }
                        if !applications.contains(where: { $0.bundleID == draft.bundleID }), !draft.bundleID.isEmpty {
                            // A saved route whose application is not running now.
                            Text(draft.applicationName).tag(draft.bundleID)
                        }
                        let playing = applications.filter(\.isRunningOutput)
                        let idle = applications.filter { !$0.isRunningOutput }
                        if !playing.isEmpty {
                            Section("Playing Audio") {
                                ForEach(playing) { applicationItem($0) }
                            }
                        }
                        if !idle.isEmpty {
                            Section("Other Applications") {
                                ForEach(idle) { applicationItem($0) }
                            }
                        }
                    }
                } footer: {
                    Text("Each app has one destination. Add routes for more apps. Turn a route off to restore that app’s normal output.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Output Device", selection: $draft.deviceUID) {
                        if device == nil {
                            Text(draft.deviceUID.isEmpty ? "Choose a Device" : "\(draft.deviceName) (not connected)")
                                .tag(draft.deviceUID)
                        }
                        ForEach(controller.deviceManager.outputDevices) { device in
                            Label(device.displayName, systemImage: device.symbolName).tag(device.uid)
                        }
                    }

                    Picker("Channels", selection: $draft.channels) {
                        if let device {
                            let pairs = stride(from: 0, to: device.outputChannelCount - 1, by: 2).map { [$0, $0 + 1] }
                            if !pairs.isEmpty {
                                Section("Stereo") {
                                    ForEach(pairs, id: \.self) { pair in
                                        Text("\(pair[0] + 1)–\(pair[1] + 1)").tag(pair)
                                    }
                                }
                            }
                            Section("Mono") {
                                ForEach(0..<device.outputChannelCount, id: \.self) { channel in
                                    Text("\(channel + 1)").tag([channel])
                                }
                            }
                        } else {
                            Text(draft.channelText).tag(draft.channels)
                        }
                    }
                    .disabled(device == nil)
                } footer: {
                    let shared = controller.sharedOutputs(for: draft)
                    if !shared.isEmpty {
                        Label("\(shared.joined(separator: " and ")) also uses these outputs. Their audio is mixed.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Route" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 480)
        .onChange(of: draft.bundleID) {
            if let application = applications.first(where: { $0.bundleID == draft.bundleID }) {
                draft.applicationName = application.name
            }
        }
        .onChange(of: draft.deviceUID) {
            guard let device else { return }
            draft.deviceName = device.displayName
            draft.channels = controller.suggestedChannels(on: device, for: draft.id)
        }
    }

    private var applications: [AppAudioSource] {
        controller.availableApplications(excluding: draft.id)
    }

    private var device: InputToOutputDevice? {
        controller.deviceManager.outputDevices.first(where: { $0.uid == draft.deviceUID })
    }

    private var isValid: Bool {
        !draft.bundleID.isEmpty && !draft.deviceUID.isEmpty && !draft.channels.isEmpty
    }

    private func applicationItem(_ application: AppAudioSource) -> some View {
        Label {
            Text(application.name)
        } icon: {
            if let icon = application.menuIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "app.dashed")
            }
        }
        .tag(application.bundleID)
    }

    private func commit() {
        if isNew {
            controller.add(draft)
        } else {
            controller.update(draft)
        }
        dismiss()
    }
}
