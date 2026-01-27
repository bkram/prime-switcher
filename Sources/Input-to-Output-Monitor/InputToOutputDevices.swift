import CoreAudio
import Foundation
import Combine

struct InputToOutputDevice: Identifiable, Hashable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool

    var stableID: String { uid }
    var identifier: AudioDeviceID { deviceID }

    var isSelectableInput: Bool { hasInput }
    var isSelectableOutput: Bool { hasOutput }

    var displayName: String { name.isEmpty ? "Device \(deviceID)" : name }

    var idString: String { String(deviceID) }

    var id: String { stableID }
}

enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .osStatus(status, operation):
            return "\(operation) failed with OSStatus \(status)."
        case let .message(message):
            return message
        }
    }
}

@discardableResult
func checkStatus(_ status: OSStatus, _ operation: String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError.osStatus(status, operation) }
    return status
}

final class InputToOutputDeviceManager: ObservableObject {
    @Published private(set) var devices: [InputToOutputDevice] = []
    @Published private(set) var inputDevices: [InputToOutputDevice] = []
    @Published private(set) var outputDevices: [InputToOutputDevice] = []

    @Published var selectedInputID: AudioDeviceID? {
        didSet { persistSelectionIfNeeded() }
    }
    @Published var selectedOutputID: AudioDeviceID? {
        didSet { persistSelectionIfNeeded() }
    }

    private let defaults = UserDefaults.standard
    private var isRefreshing = false

    private enum DefaultsKey {
        static let inputUID = "InputToOutputMonitor.selectedInputUID"
        static let outputUID = "InputToOutputMonitor.selectedOutputUID"
    }

    init() {
        refreshDevices(selectDefaults: false)
    }

    func refreshDevices(selectDefaults: Bool = false) {
        isRefreshing = true
        defer { isRefreshing = false }

        let allDevices = (try? fetchDevices()) ?? []
        devices = allDevices.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        inputDevices = devices.filter(\.hasInput)
        outputDevices = devices.filter(\.hasOutput)

        var restoredStoredInput = false
        var restoredStoredOutput = false

        if let storedInputUID = defaults.string(forKey: DefaultsKey.inputUID),
           let storedInput = inputDevices.first(where: { $0.uid == storedInputUID }) {
            selectedInputID = storedInput.identifier
            restoredStoredInput = true
        }
        if let storedOutputUID = defaults.string(forKey: DefaultsKey.outputUID),
           let storedOutput = outputDevices.first(where: { $0.uid == storedOutputUID }) {
            selectedOutputID = storedOutput.identifier
            restoredStoredOutput = true
        }

        if (selectDefaults && !restoredStoredInput) || selectedInputID == nil {
            selectedInputID = defaultDevice(scope: kAudioDevicePropertyScopeInput) ?? inputDevices.first?.identifier
        }
        if (selectDefaults && !restoredStoredOutput) || selectedOutputID == nil {
            selectedOutputID = defaultDevice(scope: kAudioDevicePropertyScopeOutput) ?? outputDevices.first?.identifier
        }

        if let selectedInputID, !inputDevices.contains(where: { $0.identifier == selectedInputID }) {
            self.selectedInputID = inputDevices.first?.identifier
        }
        if let selectedOutputID, !outputDevices.contains(where: { $0.identifier == selectedOutputID }) {
            self.selectedOutputID = outputDevices.first?.identifier
        }
    }

    func deviceName(for id: AudioDeviceID?) -> String {
        guard let id else { return "None" }
        return devices.first(where: { $0.identifier == id })?.displayName ?? "Device \(id)"
    }

    private func persistSelectionIfNeeded() {
        guard !isRefreshing else { return }

        if let uid = uid(for: selectedInputID) {
            defaults.set(uid, forKey: DefaultsKey.inputUID)
        } else {
            defaults.removeObject(forKey: DefaultsKey.inputUID)
        }

        if let uid = uid(for: selectedOutputID) {
            defaults.set(uid, forKey: DefaultsKey.outputUID)
        } else {
            defaults.removeObject(forKey: DefaultsKey.outputUID)
        }
    }

    private func uid(for deviceID: AudioDeviceID?) -> String? {
        guard let deviceID else { return nil }
        return devices.first(where: { $0.identifier == deviceID })?.uid
    }

    private func fetchDevices() throws -> [InputToOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize),
            "AudioObjectGetPropertyDataSize(kAudioHardwarePropertyDevices)"
        )

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)

        try checkStatus(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids),
            "AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)"
        )

        return ids.map { id in
            let name = (try? deviceName(id: id)) ?? ""
            let uid = (try? deviceUID(id: id)) ?? "device-\(id)"
            let hasInput = deviceHasStreams(id: id, scope: kAudioDevicePropertyScopeInput)
            let hasOutput = deviceHasStreams(id: id, scope: kAudioDevicePropertyScopeOutput)
            return InputToOutputDevice(deviceID: id, name: name, uid: uid, hasInput: hasInput, hasOutput: hasOutput)
        }
    }

    private func defaultDevice(scope: AudioObjectPropertyScope) -> AudioDeviceID? {
        let selector: AudioObjectPropertySelector = scope == kAudioDevicePropertyScopeInput
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func deviceName(id: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try getStringProperty(deviceID: id, address: &address)
    }

    private func deviceUID(id: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try getStringProperty(deviceID: id, address: &address)
    }

    private func getStringProperty(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) throws -> String {
        var cfString: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        try checkStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &cfString),
            "AudioObjectGetPropertyData(string property)"
        )

        return (cfString?.takeUnretainedValue() as String?) ?? ""
    }

    private func deviceHasStreams(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize)
        guard status == noErr else { return false }
        return dataSize > 0
    }
}
