import SwiftUI
import AppKit

@main
struct InputToOutputMonitorApp: App {
    @StateObject private var deviceManager = InputToOutputDeviceManager()
    @StateObject private var engine = InputToOutputMonitorEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceManager)
                .environmentObject(engine)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Input-to-Output Monitor") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Quit Input-to-Output Monitor") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            CommandMenu("Monitor") {
                Button(engine.isRunning ? "Stop Monitoring" : "Start Monitoring") {
                    toggleMonitoring()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart && !engine.isRunning)

                Divider()

                Button("Refresh Devices") {
                    deviceManager.refreshDevices(selectDefaults: false)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    private var canStart: Bool {
        deviceManager.selectedInputID != nil && deviceManager.selectedOutputID != nil
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
