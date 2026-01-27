import SwiftUI
import CoreAudio

struct ContentView: View {
    @EnvironmentObject private var deviceManager: InputToOutputDeviceManager
    @EnvironmentObject private var engine: InputToOutputMonitorEngine

    var body: some View {
        Form {
            Section("Devices") {
                deviceSelectors
            }

            Section("Levels") {
                LabeledContent("Stereo") {
                    StereoLevelMeterVertical(left: engine.levelLeft, right: engine.levelRight)
                        .frame(width: 160)
                        .accessibilityLabel("Stereo levels")
                        .accessibilityValue(levelValue)
                }
            }

            Section("Status") {
                LabeledContent("Monitor") {
                    StatusBadge(isRunning: engine.isRunning, message: engine.statusMessage)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 280)
        .onChange(of: deviceManager.selectedInputID) { _ in
            if engine.isRunning { engine.stop() }
        }
        .onChange(of: deviceManager.selectedOutputID) { _ in
            if engine.isRunning { engine.stop() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    deviceManager.refreshDevices(selectDefaults: false)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    toggleMonitoring()
                } label: {
                    Label(engine.isRunning ? "Stop" : "Start",
                          systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart && !engine.isRunning)
            }
        }
    }

    private var deviceSelectors: some View {
        Group {
            LabeledContent("Input") {
                HStack {
                    Spacer()
                    Picker("Input Device", selection: $deviceManager.selectedInputID) {
                        ForEach(deviceManager.inputDevices) { device in
                            Text(device.displayName).tag(Optional(device.identifier))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240, alignment: .trailing)
                    .accessibilityLabel("Input device")
                    .accessibilityValue(deviceManager.deviceName(for: deviceManager.selectedInputID))
                }
            }

            LabeledContent("Output") {
                HStack {
                    Spacer()
                    Picker("Output Device", selection: $deviceManager.selectedOutputID) {
                        ForEach(deviceManager.outputDevices) { device in
                            Text(device.displayName).tag(Optional(device.identifier))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240, alignment: .trailing)
                    .accessibilityLabel("Output device")
                    .accessibilityValue(deviceManager.deviceName(for: deviceManager.selectedOutputID))
                }
            }
        }
    }

    private var canStart: Bool {
        deviceManager.selectedInputID != nil && deviceManager.selectedOutputID != nil
    }

    private var levelValue: String {
        let left = Int((max(0, min(1, engine.levelLeft)) * 100).rounded())
        let right = Int((max(0, min(1, engine.levelRight)) * 100).rounded())
        return "Left \(left) percent, Right \(right) percent"
    }

    private func toggleMonitoring() {
        if engine.isRunning {
            engine.stop()
            return
        }
        guard let inputID = deviceManager.selectedInputID,
              let outputID = deviceManager.selectedOutputID else {
            return
        }
        engine.start(inputDeviceID: inputID, outputDeviceID: outputID)
    }
}

private struct StereoLevelMeterVertical: View {
    let left: Float
    let right: Float

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("L")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LevelBar(level: left, tint: .green)
            }
            HStack(spacing: 6) {
                Text("R")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LevelBar(level: right, tint: .green)
            }
        }
        .frame(height: 28)
        .accessibilityLabel("Stereo level meter")
    }
}

private struct StatusBadge: View {
    let isRunning: Bool
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(message)
                .foregroundStyle(isRunning ? .primary : .secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Monitor status")
        .accessibilityValue(message)
    }
}

private struct LevelBar: View {
    let level: Float
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, CGFloat(level)))
            let width = max(2, geo.size.width * clamped)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint)
                    .frame(width: width)
            }
        }
        .frame(minWidth: 80, maxWidth: .infinity)
        .frame(height: 8)
    }
}
