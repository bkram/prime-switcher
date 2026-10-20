import AppKit
import Combine
import CoreAudio
import Foundation

struct AppAudioSource: Identifiable, Hashable {
    let processObjectIDs: [AudioObjectID]
    let processIDs: [pid_t]
    let bundleID: String
    /// Bundle identifiers Core Audio reported for the member processes, such
    /// as com.google.Chrome.helper; routes saved under one of them still match.
    let reportedBundleIDs: Set<String>
    let name: String
    let isRunningOutput: Bool
    /// Full-size application icon, for the route diagram.
    let icon: NSImage?
    /// The same icon at menu size; menus ignore SwiftUI frame modifiers.
    let menuIcon: NSImage?

    var id: String { bundleID.isEmpty ? processObjectIDs.map(String.init).joined(separator: ",") : bundleID }

    var detail: String {
        isRunningOutput ? "Playing audio" : "Not playing"
    }
}

@MainActor
final class AppAudioProcessManager: ObservableObject {
    @Published private(set) var applications: [AppAudioSource] = []
    @Published var selectedApplicationID: String?
    @Published private(set) var errorMessage: String?

    init(refreshImmediately: Bool = true) {
        if refreshImmediately { refresh() }
    }

    func refresh() {
        do {
            let previousSelection = selectedApplicationID
            applications = try Self.fetchApplications()
            errorMessage = nil

            // Never pick an app on the user's behalf: selecting one starts its route
            // and silences its normal output.
            if let previousSelection, !applications.contains(where: { $0.id == previousSelection }) {
                selectedApplicationID = nil
            }
        } catch {
            applications = []
            selectedApplicationID = nil
            errorMessage = error.localizedDescription
        }
    }

    func application(for id: String?) -> AppAudioSource? {
        guard let id else { return nil }
        return applications.first(where: { $0.id == id })
    }

    private struct RawProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let reportedBundleID: String
        let bundleID: String
        let name: String
        let isRunningOutput: Bool
        let isRegularApplication: Bool
        let appURL: URL?
    }

    nonisolated private static func fetchApplications() throws -> [AppAudioSource] {
        let processIDs: [AudioObjectID] = try getArrayProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rawProcesses = processIDs.compactMap { objectID -> RawProcess? in
            guard let pid = try? getValueProperty(
                pid_t.self,
                objectID: objectID,
                selector: kAudioProcessPropertyPID,
                scope: kAudioObjectPropertyScopeGlobal
            ), pid != ownPID else {
                return nil
            }

            let reportedBundleID = (try? getStringProperty(
                objectID: objectID,
                selector: kAudioProcessPropertyBundleID,
                scope: kAudioObjectPropertyScopeGlobal
            )) ?? ""
            let runningValue = (try? getValueProperty(
                UInt32.self,
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningOutput,
                scope: kAudioObjectPropertyScopeGlobal
            )) ?? 0

            // Helper processes, such as the one Chrome plays audio from, are not
            // NSRunningApplications, so ask the kernel for the executable path.
            let runningApplication = NSRunningApplication(processIdentifier: pid)
            let identity = owningApplicationIdentity(
                executableURL: runningApplication?.executableURL ?? executableURL(pid: pid),
                reportedBundleID: reportedBundleID,
                fallbackPID: pid
            )

            return RawProcess(
                objectID: objectID,
                pid: pid,
                reportedBundleID: reportedBundleID,
                bundleID: identity.bundleID,
                name: identity.name,
                isRunningOutput: runningValue != 0,
                isRegularApplication: runningApplication?.activationPolicy == .regular,
                appURL: identity.appURL
            )
        }

        let grouped = Dictionary(grouping: rawProcesses) { process in
            process.bundleID.isEmpty ? "pid:\(process.pid)" : process.bundleID
        }

        // Core Audio lists every client, including system daemons. Offer only
        // applications a person runs, plus anything that is playing right now.
        return grouped.compactMap { key, members in
            guard members.contains(where: { $0.isRegularApplication || $0.isRunningOutput }) else {
                return nil
            }
            let preferredName = members.first(where: { !$0.name.isEmpty })?.name ?? key
            let appURL = members.lazy.compactMap(\.appURL).first
            return AppAudioSource(
                processObjectIDs: members.map(\.objectID).sorted(),
                processIDs: members.map(\.pid).sorted(),
                bundleID: members.first?.bundleID ?? "",
                reportedBundleIDs: Set(members.map(\.reportedBundleID).filter { !$0.isEmpty }),
                name: preferredName,
                isRunningOutput: members.contains(where: \.isRunningOutput),
                icon: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                menuIcon: appURL.map(menuIcon(forApplicationAt:))
            )
        }
        .sorted {
            if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func executableURL(pid: pid_t) -> URL? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        guard let path = String(bytes: buffer.prefix(Int(length)), encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Menus draw images at their own size, so shrink the icon to menu size.
    nonisolated private static func menuIcon(forApplicationAt url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    nonisolated private static func owningApplicationIdentity(
        executableURL: URL?,
        reportedBundleID: String,
        fallbackPID: pid_t
    ) -> (bundleID: String, name: String, appURL: URL?) {
        if let executableURL,
           let appIndex = executableURL.pathComponents.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appURL = URL(fileURLWithPath: NSString.path(withComponents: Array(executableURL.pathComponents[...appIndex])))
            if let bundle = Bundle(url: appURL) {
                return (
                    bundle.bundleIdentifier ?? reportedBundleID,
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? appURL.deletingPathExtension().lastPathComponent,
                    appURL
                )
            }
        }

        let bundleID = reportedBundleID.isEmpty ? "pid:\(fallbackPID)" : reportedBundleID
        return (bundleID, reportedBundleID.isEmpty ? "Process \(fallbackPID)" : reportedBundleID, nil)
    }
}

/// Reads a fixed-size Core Audio property.
///
/// The value type is passed explicitly. Inferring it from the call site is unsafe:
/// in `let x: UInt32 = (try? getValueProperty(...)) ?? 0` Swift picks
/// `T == UInt32?`, sends a 5-byte buffer, and the HAL rejects it with
/// "wrong data size".
func getValueProperty<T>(
    _ type: T.Type,
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<T>.size,
        alignment: MemoryLayout<T>.alignment
    )
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
    var size = UInt32(MemoryLayout<T>.size)
    try checkStatus(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage),
        "Read Core Audio property \(selector)"
    )
    return storage.load(as: T.self)
}

func getArrayProperty<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) throws -> [T] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var size: UInt32 = 0
    try checkStatus(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "Size Core Audio property \(selector)")
    guard size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { storage.deallocate() }
    try checkStatus(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage), "Read Core Audio property \(selector)")
    return Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: T.self), count: count))
}

func getStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) throws -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try checkStatus(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "Read Core Audio string property \(selector)")
    return (value?.takeRetainedValue() as String?) ?? ""
}
