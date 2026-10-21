import SwiftUI
import AppKit

@main
struct InputToOutputMonitorApp: App {
    @NSApplicationDelegateAdaptor(PrimeSwitcherAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var deviceManager: InputToOutputDeviceManager
    @StateObject private var processManager: AppAudioProcessManager
    @StateObject private var interfaceController: InterfaceRouteController
    @StateObject private var routeController: AudioRouteController

    init() {
        // The route controller watches the same device and process lists the
        // views show, so all three share one instance each.
        let deviceManager = InputToOutputDeviceManager()
        let processManager = AppAudioProcessManager()
        _deviceManager = StateObject(wrappedValue: deviceManager)
        _interfaceController = StateObject(wrappedValue: InterfaceRouteController(devices: deviceManager))
        _processManager = StateObject(wrappedValue: processManager)
        _routeController = StateObject(wrappedValue: AudioRouteController(
            processManager: processManager,
            deviceManager: deviceManager
        ))
    }

    var body: some Scene {
        Window("Prime Switcher", id: "main") {
            ContentView()
                .environmentObject(deviceManager)
                .environmentObject(processManager)
                .environmentObject(routeController)
                .environmentObject(interfaceController)
                .onAppear {
                    appDelegate.reopenMainWindow = { openWindow(id: "main") }
                    runSelfTestIfRequested()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Prime Switcher") {
                    showAboutPanel()
                }
            }
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Quit Prime Switcher") {
                    stopAndQuit()
                }
                .keyboardShortcut("q")
            }
            CommandGroup(replacing: .newItem) {
                Button("New App Route…") {
                    openWindow(id: "main")
                    UserDefaults.standard.set(1, forKey: "PrimeSwitcher.selectedSection")
                    routeController.isPresentingNewRoute = true
                }.keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(before: .windowArrangement) {
                Button("Show Prime Switcher") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
            CommandMenu("Routes") {
                Button("Turn Off All Routes") {
                    routeController.turnAllOff()
                    for route in interfaceController.routes { interfaceController.setEnabled(route, false) }
                }
                Divider()
                Button("Refresh Applications and Interfaces") { routeController.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    private func showAboutPanel() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let credits = NSMutableAttributedString(
            string: "Audio routing for apps and interfaces.\n\n",
            attributes: attributes
        )
        var linkAttributes = attributes
        linkAttributes[.link] = URL(string: "https://github.com/bkram/prime-switcher")
        credits.append(NSAttributedString(string: "Prime Switcher on GitHub", attributes: linkAttributes))
        if bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") == nil {
            credits.append(NSAttributedString(
                string: "\n\n© 2026 Bkram Developments. All rights reserved.",
                attributes: attributes
            ))
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Prime Switcher",
            .applicationVersion: version,
            .version: build == version ? "" : build,
            .credits: credits
        ])
    }

    /// `--route-self-test <bundle ID>,<output UID>,<left>,<right> …`: run each
    /// route, unmuted, for three seconds, write the measured levels to
    /// /tmp/router-self-test.txt and quit. Channels are one-based. Run with
    /// `open -n -W "Prime Switcher.app" --args …` so the test uses
    /// the app's own System Audio Recording permission.
    private func runSelfTestIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--route-self-test") else { return }
        let specs = arguments[(flag + 1)...].filter { !$0.hasPrefix("-") }.map { $0.split(separator: ",").map(String.init) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            var report = ""
            processManager.refresh()
            deviceManager.refreshDevices(selectDefaults: false)
            var runners: [(String, RouteRunner)] = []
            for spec in specs where spec.count >= 2 {
                let channels = spec.dropFirst(2).compactMap { Int($0) }.map { $0 - 1 }
                let label = spec.joined(separator: ",")
                guard let application = processManager.applications.first(where: { $0.bundleID == spec[0] }),
                      let device = deviceManager.outputDevices.first(where: { $0.uid == spec[1] }) else {
                    report += "\(label): application or device not found\n"
                    continue
                }
                let runner = RouteRunner()
                runner.start(
                    application: application,
                    outputDevice: device,
                    outputChannels: channels.isEmpty ? [0, 1] : channels,
                    mutesApplication: false
                )
                report += "\(label): running=\(runner.isRunning) failure=\(runner.failureMessage ?? "none")\n"
                runners.append((label, runner))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for (label, runner) in runners {
                    report += "\(label): peak=\(runner.levelMonitor.recentPeak)\n"
                    runner.stop()
                }
                try? report.write(toFile: "/tmp/router-self-test.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    private func stopAndQuit() {
        interfaceController.stopAll()
        routeController.stopAll()
        NSApp.terminate(nil)
    }
}

@MainActor
final class PrimeSwitcherAppDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenMainWindow?()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
