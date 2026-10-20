import Combine
import CoreAudio
import Foundation

/// One Float32 the audio callback writes its latest peak into and the main
/// thread reads and clears. A torn read only costs one meter frame, so no lock.
struct RoutePeakSlot: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float32>
}

private final class AppAudioRouteSession {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var ioProcID: AudioDeviceIOProcID?
    var isStarted = false
    var processObjectIDs: [AudioObjectID] = []
    let peak: RoutePeakSlot = {
        let pointer = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return RoutePeakSlot(pointer: pointer)
    }()

    func cleanup() {
        if isStarted, aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            isStarted = false
        }
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        cleanup()
        // Safe only here: cleanup() has stopped the callback that writes it.
        peak.pointer.deallocate()
    }
}

/// Level of the active route for the route diagram, published apart from the
/// engine so 30 Hz updates redraw only the meter.
@MainActor
final class RouteLevelMonitor: ObservableObject {
    static let historyLength = 28

    /// Recent levels, oldest first, each 0...1 on a -60...0 dBFS scale.
    @Published private(set) var history = Array(repeating: Float(0), count: historyLength)
    /// True when the routed app reports running output but the route has
    /// carried only silence for two seconds. That is how a missing permission
    /// shows, but some apps also keep their device running while silent.
    @Published private(set) var isReceivingSilence = false

    private var timer: Timer?
    private var silentTicks = 0
    private var ticks = 0
    private var appIsPlaying = false

    fileprivate func start(peak: RoutePeakSlot, processObjectIDs: [AudioObjectID]) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick(peak: peak, processObjectIDs: processObjectIDs)
            }
        }
    }

    /// Highest level in the recent history, 0...1. Used by the self-test.
    var recentPeak: Float { history.max() ?? 0 }

    func stop() {
        timer?.invalidate()
        timer = nil
        history = Array(repeating: 0, count: Self.historyLength)
        isReceivingSilence = false
        silentTicks = 0
        ticks = 0
    }

    private func tick(peak: RoutePeakSlot, processObjectIDs: [AudioObjectID]) {
        let value = peak.pointer.pointee
        peak.pointer.pointee = 0

        let decibels = 20 * log10(max(value, 1e-6))
        let level = max(0, min(1, (decibels + 60) / 60))
        history.removeFirst()
        history.append(level)

        // Re-check about once a second whether the app is producing output.
        if ticks % 30 == 0 {
            appIsPlaying = processObjectIDs.contains { objectID in
                ((try? getValueProperty(
                    UInt32.self,
                    objectID: objectID,
                    selector: kAudioProcessPropertyIsRunningOutput,
                    scope: kAudioObjectPropertyScopeGlobal
                )) ?? 0) != 0
            }
        }
        ticks += 1

        silentTicks = (appIsPlaying && value == 0) ? silentTicks + 1 : 0
        let silent = silentTicks >= 60
        if silent != isReceivingSilence { isReceivingSilence = silent }
    }
}

/// Runs one route: a tap on one application, a private route device on one
/// output, and the callback that copies the tap to the chosen channels.
/// AudioRouteController keeps one per enabled route.
@MainActor
final class RouteRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Not routed"
    @Published private(set) var failureMessage: String?
    @Published private(set) var routedApplicationName: String?

    let levelMonitor = RouteLevelMonitor()
    private var session: AppAudioRouteSession?

    func start(
        application: AppAudioSource,
        outputDevice: InputToOutputDevice,
        outputChannels: [Int],
        mutesApplication: Bool = true
    ) {
        guard !isRunning else { return }
        statusMessage = "Starting route…"
        failureMessage = nil

        let newSession = AppAudioRouteSession()
        do {
            try configure(
                session: newSession,
                processObjectIDs: application.processObjectIDs,
                applicationName: application.name,
                outputDevice: outputDevice,
                outputChannels: outputChannels,
                mutesApplication: mutesApplication
            )
            session = newSession
            routedApplicationName = application.name
            isRunning = true
            levelMonitor.start(peak: newSession.peak, processObjectIDs: newSession.processObjectIDs)
            statusMessage = "Routing \(application.name) to \(outputDevice.displayName)"
        } catch {
            newSession.cleanup()
            session = nil
            routedApplicationName = nil
            isRunning = false
            statusMessage = "Not routed"
            failureMessage = error.localizedDescription
        }
    }

    func stop() {
        levelMonitor.stop()
        session?.cleanup()
        session = nil
        routedApplicationName = nil
        isRunning = false
        statusMessage = "Not routed"
        failureMessage = nil
    }

    private func configure(
        session: AppAudioRouteSession,
        processObjectIDs: [AudioObjectID],
        applicationName: String,
        outputDevice: InputToOutputDevice,
        outputChannels: [Int],
        mutesApplication: Bool
    ) throws {
        guard !processObjectIDs.isEmpty else {
            throw CoreAudioError.message("The selected application has no active Core Audio process.")
        }
        guard outputDevice.hasOutput else {
            throw CoreAudioError.message("The selected destination has no output channels.")
        }
        let selectedChannels = Array(Set(outputChannels)).sorted()
        guard (1...2).contains(selectedChannels.count),
              selectedChannels.allSatisfy({ (0..<outputDevice.outputChannelCount).contains($0) }) else {
            throw CoreAudioError.message("Select one or two valid destination channels.")
        }

        // Apple's tap pattern: give the description its own UUID and use that UUID
        // as the tap's UID in the aggregate device's tap list.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Application Audio Router: \(applicationName)"
        description.isPrivate = true
        description.muteBehavior = mutesApplication ? .mutedWhenTapped : .unmuted

        try checkStatus(
            AudioHardwareCreateProcessTap(description, &session.tapID),
            "Create application audio tap"
        )
        session.processObjectIDs = processObjectIDs
        let tapUID = description.uuid.uuidString

        try validateRouteFormats(tapID: session.tapID, outputDeviceID: outputDevice.deviceID)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Application Audio Router Route",
            kAudioAggregateDeviceUIDKey: "com.mrk.applicationaudiorouter.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDevice.uid,
            // Off on purpose: when on, AudioDeviceStart blocks until the tapped app
            // plays audio, which would freeze the window for a silent app.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDevice.uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        try checkStatus(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &session.aggregateID),
            "Create private route device"
        )
        try checkAlive(deviceID: session.aggregateID)

        let hardwareInputBufferCount = try streamBufferCount(
            deviceID: outputDevice.deviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        let leftOutputChannel = selectedChannels[0]
        let rightOutputChannel = selectedChannels.count > 1 ? selectedChannels[1] : nil

        var ioProcID: AudioDeviceIOProcID?
        let aggregateID = session.aggregateID
        let peak = session.peak
        try checkStatus(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInputData, _, outOutputData, _ in
                routeAudioBuffers(
                    inputData: inInputData,
                    outputData: outOutputData,
                    tapStartBuffer: hardwareInputBufferCount,
                    leftOutputChannel: leftOutputChannel,
                    rightOutputChannel: rightOutputChannel,
                    peak: peak
                )
            },
            "Create route callback"
        )
        guard let ioProcID else {
            throw CoreAudioError.message("Core Audio did not create a route callback.")
        }
        session.ioProcID = ioProcID

        try checkStatus(AudioDeviceStart(session.aggregateID, ioProcID), "Start application route")
        session.isStarted = true
    }

    /// A private aggregate device is alive as soon as it is created, so one read
    /// is enough. Polling here would block the main thread.
    private func checkAlive(deviceID: AudioDeviceID) throws {
        let isAlive = try getValueProperty(
            UInt32.self,
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard isAlive != 0 else {
            throw CoreAudioError.message("The private route device did not become ready.")
        }
    }
}

private func validateRouteFormats(tapID: AudioObjectID, outputDeviceID: AudioDeviceID) throws {
    let tapFormat = try getValueProperty(
        AudioStreamBasicDescription.self,
        objectID: tapID,
        selector: kAudioTapPropertyFormat,
        scope: kAudioObjectPropertyScopeGlobal
    )
    let outputStreams: [AudioStreamID] = try getArrayProperty(
        objectID: outputDeviceID,
        selector: kAudioDevicePropertyStreams,
        scope: kAudioDevicePropertyScopeOutput
    )
    guard !outputStreams.isEmpty else {
        throw CoreAudioError.message("The selected destination has no output streams.")
    }

    let outputFormats: [AudioStreamBasicDescription] = try outputStreams.map { streamID in
        try getValueProperty(
            AudioStreamBasicDescription.self,
            objectID: streamID,
            selector: kAudioStreamPropertyVirtualFormat,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func isSupportedFloatPCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    }

    guard isSupportedFloatPCM(tapFormat), outputFormats.allSatisfy(isSupportedFloatPCM) else {
        throw CoreAudioError.message("This route requires 32-bit floating-point PCM streams. The selected device uses an unsupported format.")
    }
    guard outputFormats.allSatisfy({ abs($0.mSampleRate - tapFormat.mSampleRate) < 1 }) else {
        throw CoreAudioError.message(
            "The application tap is \(Int(tapFormat.mSampleRate)) Hz, but the selected output uses a different sample rate. Match the device sample rates in Audio MIDI Setup and try again."
        )
    }
}

private func streamBufferCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    if sizeStatus != noErr || size == 0 { return 0 }

    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    try checkStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage),
        "Read device stream configuration"
    )
    let list = storage.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).count
}

private func routeAudioBuffers(
    inputData: UnsafePointer<AudioBufferList>,
    outputData: UnsafeMutablePointer<AudioBufferList>,
    tapStartBuffer: Int,
    leftOutputChannel: Int,
    rightOutputChannel: Int?,
    peak: RoutePeakSlot
) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputs = UnsafeMutableAudioBufferListPointer(outputData)

    for index in outputs.indices {
        guard let output = outputs[index].mData else { continue }
        memset(output, 0, Int(outputs[index].mDataByteSize))
    }

    guard tapStartBuffer < inputs.count, !outputs.isEmpty,
          let leftDestination = locateOutputChannel(leftOutputChannel, in: outputs) else {
        return
    }
    let tapBufferCount = inputs.count - tapStartBuffer
    let firstInput = inputs[tapStartBuffer]
    guard let firstInputData = firstInput.mData else { return }
    let firstInputChannels = max(1, Int(firstInput.mNumberChannels))
    let firstInputFrames = Int(firstInput.mDataByteSize) / (firstInputChannels * MemoryLayout<Float32>.size)

    let secondInputData = tapBufferCount > 1 ? inputs[tapStartBuffer + 1].mData : nil
    let secondInputFrames = tapBufferCount > 1
        ? Int(inputs[tapStartBuffer + 1].mDataByteSize) / max(1, Int(inputs[tapStartBuffer + 1].mNumberChannels) * MemoryLayout<Float32>.size)
        : firstInputFrames

    let leftOutputBuffer = outputs[leftDestination.bufferIndex]
    guard let leftOutputData = leftOutputBuffer.mData else { return }
    let leftOutputChannels = max(1, Int(leftOutputBuffer.mNumberChannels))
    let leftOutputFrames = Int(leftOutputBuffer.mDataByteSize) / (leftOutputChannels * MemoryLayout<Float32>.size)

    let rightDestination = rightOutputChannel.flatMap { locateOutputChannel($0, in: outputs) }
    var frameCount = min(firstInputFrames, leftOutputFrames)
    if firstInputChannels < 2, secondInputData != nil {
        frameCount = min(frameCount, secondInputFrames)
    }
    if let rightDestination {
        let rightBuffer = outputs[rightDestination.bufferIndex]
        let rightChannels = max(1, Int(rightBuffer.mNumberChannels))
        frameCount = min(frameCount, Int(rightBuffer.mDataByteSize) / (rightChannels * MemoryLayout<Float32>.size))
    }

    let firstSource = firstInputData.assumingMemoryBound(to: Float32.self)
    let secondSource = secondInputData?.assumingMemoryBound(to: Float32.self)
    let leftOutput = leftOutputData.assumingMemoryBound(to: Float32.self)

    var blockPeak: Float32 = 0
    defer { peak.pointer.pointee = max(peak.pointer.pointee, blockPeak) }

    for frame in 0..<frameCount {
        let leftSample = firstSource[frame * firstInputChannels]
        let rightSample: Float32
        if firstInputChannels >= 2 {
            rightSample = firstSource[frame * firstInputChannels + 1]
        } else if let secondSource {
            rightSample = secondSource[frame]
        } else {
            rightSample = leftSample
        }
        blockPeak = max(blockPeak, abs(leftSample), abs(rightSample))

        if let rightDestination,
           let rightOutputData = outputs[rightDestination.bufferIndex].mData {
            leftOutput[frame * leftOutputChannels + leftDestination.localChannel] = leftSample
            let rightChannels = max(1, Int(outputs[rightDestination.bufferIndex].mNumberChannels))
            let rightOutput = rightOutputData.assumingMemoryBound(to: Float32.self)
            rightOutput[frame * rightChannels + rightDestination.localChannel] = rightSample
        } else {
            leftOutput[frame * leftOutputChannels + leftDestination.localChannel] = (leftSample + rightSample) * 0.5
        }
    }
}

private func locateOutputChannel(
    _ requestedChannel: Int,
    in outputs: UnsafeMutableAudioBufferListPointer
) -> (bufferIndex: Int, localChannel: Int)? {
    var channelBase = 0
    for bufferIndex in outputs.indices {
        let channelCount = Int(outputs[bufferIndex].mNumberChannels)
        if requestedChannel < channelBase + channelCount {
            return (bufferIndex, requestedChannel - channelBase)
        }
        channelBase += channelCount
    }
    return nil
}
