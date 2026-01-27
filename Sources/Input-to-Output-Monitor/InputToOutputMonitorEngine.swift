import AudioToolbox
import AudioUnit
import CoreAudio
import Foundation
import os
import Combine
import Darwin
import AVFoundation

private func makeASBD(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
    let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
    let bytesPerFrame = bytesPerSample * channels

    return AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 8 * bytesPerSample,
        mReserved: 0
    )
}

private final class AudioRingBuffer {
    private var lock = os_unfair_lock_s()
    private let capacityFrames: Int
    private let bytesPerFrame: Int
    private var storage: Data
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var availableFrames: Int = 0

    init(capacityFrames: Int, bytesPerFrame: Int) {
        self.capacityFrames = max(capacityFrames, 1)
        self.bytesPerFrame = max(bytesPerFrame, 1)
        self.storage = Data(count: self.capacityFrames * self.bytesPerFrame)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        os_unfair_lock_unlock(&lock)
    }

    func write(from source: UnsafeRawPointer, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let framesToWrite = min(frames, capacityFrames)
        let startFrame = (availableFrames == capacityFrames) ? readIndex : writeIndex

        if availableFrames == capacityFrames {
            // Overwrite the oldest data when full.
            readIndex = (readIndex + framesToWrite) % capacityFrames
            availableFrames = capacityFrames - framesToWrite
        }

        storage.withUnsafeMutableBytes { destBytes in
            guard let destBase = destBytes.baseAddress else { return }
            let destPtr = destBase.assumingMemoryBound(to: UInt8.self)
            let srcPtr = source.assumingMemoryBound(to: UInt8.self)

            let firstChunkFrames = min(framesToWrite, capacityFrames - startFrame)
            let firstChunkBytes = firstChunkFrames * bytesPerFrame
            memcpy(destPtr.advanced(by: startFrame * bytesPerFrame), srcPtr, firstChunkBytes)

            let remainingFrames = framesToWrite - firstChunkFrames
            if remainingFrames > 0 {
                let remainingBytes = remainingFrames * bytesPerFrame
                memcpy(destPtr, srcPtr.advanced(by: firstChunkBytes), remainingBytes)
            }
        }

        writeIndex = (startFrame + framesToWrite) % capacityFrames
        availableFrames = min(availableFrames + framesToWrite, capacityFrames)
    }

    func read(into destination: UnsafeMutableRawPointer, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let framesToRead = min(frames, availableFrames)
        guard framesToRead > 0 else { return 0 }

        let firstChunkFrames = min(framesToRead, capacityFrames - readIndex)
        let firstChunkBytes = firstChunkFrames * bytesPerFrame

        storage.withUnsafeBytes { srcBytes in
            guard let srcBase = srcBytes.baseAddress else { return }
            let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
            let destPtr = destination.assumingMemoryBound(to: UInt8.self)

            memcpy(destPtr, srcPtr.advanced(by: readIndex * bytesPerFrame), firstChunkBytes)

            let remainingFrames = framesToRead - firstChunkFrames
            if remainingFrames > 0 {
                let remainingBytes = remainingFrames * bytesPerFrame
                memcpy(destPtr.advanced(by: firstChunkBytes), srcPtr, remainingBytes)
            }
        }

        readIndex = (readIndex + framesToRead) % capacityFrames
        availableFrames -= framesToRead

        return framesToRead
    }
}

@MainActor
final class InputToOutputMonitorEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var levelLeft: Float = 0
    @Published private(set) var levelRight: Float = 0

    nonisolated(unsafe) fileprivate var inputUnit: AudioUnit?
    nonisolated(unsafe) fileprivate var outputUnit: AudioUnit?
    nonisolated(unsafe) private var ringBuffer: AudioRingBuffer?
    nonisolated(unsafe) private var streamFormat: AudioStreamBasicDescription?
    nonisolated(unsafe) private var rawLevelLeft: Float = 0
    nonisolated(unsafe) private var rawLevelRight: Float = 0

    private var meterTimer: Timer?
    private var isRequestingPermission: Bool = false
    private var isStarting: Bool = false

    deinit {
        cleanupUnits()
    }

    func start(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) {
        guard !isRunning && !isStarting else { return }
        isStarting = true
        print("InputToOutputMonitorEngine.start called")

        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Mic permission status: \(permission)")
        switch permission {
        case .authorized:
            startInternal(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
            return
        case .notDetermined:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            setState(isRunning: false, message: "Requesting microphone access…")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRequestingPermission = false
                    print("Mic permission granted: \(granted)")
                    if granted {
                        self.startInternal(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
                    } else {
                        self.isStarting = false
                        self.setState(isRunning: false, message: "Microphone access denied")
                    }
                }
            }
            return
        default:
            isStarting = false
            setState(isRunning: false, message: "Microphone access denied")
            return
        }

    }

    private func startInternal(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) {
        defer { isStarting = false }
        print("InputToOutputMonitorEngine.startInternal begin")
        do {
            try stopInternal()
            try configureAndStart(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
            print("InputToOutputMonitorEngine.startInternal success")
            setState(isRunning: true, message: "Monitoring")
        } catch {
            print("InputToOutputMonitorEngine.startInternal error: \(error)")
            setState(isRunning: false, message: error.localizedDescription)
        }
    }

    func stop() {
        do {
            try stopInternal()
            isStarting = false
            setState(isRunning: false, message: "Stopped")
        } catch {
            setState(isRunning: false, message: error.localizedDescription)
        }
    }

    @MainActor
    private func setState(isRunning: Bool, message: String) {
        self.isRunning = isRunning
        self.statusMessage = message
    }

    private func configureAndStart(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        let inputSampleRate = try deviceSampleRate(deviceID: inputDeviceID)
        let inputChannels = max(1, try deviceChannelCount(deviceID: inputDeviceID, scope: kAudioDevicePropertyScopeInput))
        let desiredChannels = min(inputChannels, 2)

        var asbd = makeASBD(sampleRate: inputSampleRate, channels: desiredChannels)

        let inUnit = try makeHALAudioUnit()
        try configureInputUnit(inUnit, deviceID: inputDeviceID, format: &asbd)

        let outUnit = try makeHALAudioUnit()
        try configureOutputUnit(outUnit, deviceID: outputDeviceID, format: &asbd)

        let capacityFrames = Int(inputSampleRate * 2.0)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        ringBuffer = AudioRingBuffer(capacityFrames: capacityFrames, bytesPerFrame: bytesPerFrame)
        ringBuffer?.reset()
        streamFormat = asbd

        inputUnit = inUnit
        outputUnit = outUnit

        startMetering()
        try checkStatus(AudioOutputUnitStart(inUnit), "AudioOutputUnitStart(input)")
        try checkStatus(AudioOutputUnitStart(outUnit), "AudioOutputUnitStart(output)")
    }

    private func stopInternal() throws {
        cleanupUnits()
        ringBuffer = nil
        streamFormat = nil
        stopMetering()
    }

    nonisolated private func cleanupUnits() {
        if let inputUnit {
            _ = AudioOutputUnitStop(inputUnit)
            _ = AudioUnitUninitialize(inputUnit)
        }
        if let outputUnit {
            _ = AudioOutputUnitStop(outputUnit)
            _ = AudioUnitUninitialize(outputUnit)
        }
        inputUnit = nil
        outputUnit = nil
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateMeterLevelsFromRaw()
            }
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        levelLeft = 0
        levelRight = 0
        rawLevelLeft = 0
        rawLevelRight = 0
    }

    private func updateMeterLevelsFromRaw() {
        // Attack/release smoothing on a 0...1 dBFS-normalized signal.
        let attack: Float = 0.55
        let release: Float = 0.92
        levelLeft = smoothMeter(current: levelLeft, target: rawLevelLeft, attack: attack, release: release)
        levelRight = smoothMeter(current: levelRight, target: rawLevelRight, attack: attack, release: release)
    }

    private func makeHALAudioUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError.message("Unable to find HALOutput audio component.")
        }

        var unit: AudioUnit?
        try checkStatus(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew(HALOutput)")
        guard let unit else {
            throw CoreAudioError.message("Failed to create HALOutput audio unit.")
        }
        return unit
    }

    private func configureInputUnit(_ unit: AudioUnit, deviceID: AudioDeviceID, format: inout AudioStreamBasicDescription) throws {
        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0

        try checkStatus(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Enable input on HAL unit"
        )
        try checkStatus(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Disable output on HAL unit"
        )

        var deviceIDVar = deviceID
        try checkStatus(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "Set input device"
        )

        try checkStatus(
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "Set input stream format"
        )

        var callback = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        try checkStatus(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "Set input callback"
        )

        try checkStatus(AudioUnitInitialize(unit), "AudioUnitInitialize(input)")
    }

    private func configureOutputUnit(_ unit: AudioUnit, deviceID: AudioDeviceID, format: inout AudioStreamBasicDescription) throws {
        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0

        try checkStatus(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Enable output on HAL unit"
        )
        try checkStatus(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Disable input on HAL unit"
        )

        var deviceIDVar = deviceID
        try checkStatus(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "Set output device"
        )

        try checkStatus(
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "Set output stream format"
        )

        var callback = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        try checkStatus(
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "Set output render callback"
        )

        try checkStatus(AudioUnitInitialize(unit), "AudioUnitInitialize(output)")
    }

    nonisolated fileprivate func handleInput(unit: AudioUnit, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, busNumber: UInt32, frameCount: UInt32) -> OSStatus {
        guard let ringBuffer, let streamFormat else { return noErr }

        let frames = Int(frameCount)
        let bytesPerFrame = Int(streamFormat.mBytesPerFrame)
        let byteCount = frames * bytesPerFrame

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer {
            bufferList.deallocate()
        }

        let audioData = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float32>.alignment)
        defer { audioData.deallocate() }

        bufferList.pointee.mNumberBuffers = 1
        bufferList.pointee.mBuffers.mNumberChannels = streamFormat.mChannelsPerFrame
        bufferList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        bufferList.pointee.mBuffers.mData = audioData

        let status = AudioUnitRender(unit, flags, timeStamp, busNumber, frameCount, bufferList)
        guard status == noErr else { return status }

        updateRawLevels(from: audioData, frames: frames, channels: Int(streamFormat.mChannelsPerFrame))
        ringBuffer.write(from: audioData, frames: frames)
        return noErr
    }

    nonisolated fileprivate func renderOutput(ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> OSStatus {
        guard let ringBuffer, let streamFormat else { return noErr }

        let channels = Int(streamFormat.mChannelsPerFrame)
        let framesRequested = Int(frameCount)
        let bytesPerFrame = Int(streamFormat.mBytesPerFrame)
        let byteCount = framesRequested * bytesPerFrame

        let interleavedBuffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float32>.alignment)
        defer { interleavedBuffer.deallocate() }

        let framesRead = ringBuffer.read(into: interleavedBuffer, frames: framesRequested)
        if framesRead < framesRequested {
            let remainingFrames = framesRequested - framesRead
            let remainingBytes = remainingFrames * bytesPerFrame
            memset(interleavedBuffer.advanced(by: framesRead * bytesPerFrame), 0, remainingBytes)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let dest = buffer.mData else { return noErr }
            memcpy(dest, interleavedBuffer, min(Int(buffer.mDataByteSize), byteCount))
            buffers[0].mDataByteSize = UInt32(byteCount)
            return noErr
        }

        // De-interleave for devices that provide one buffer per channel.
        let src = interleavedBuffer.assumingMemoryBound(to: Float32.self)
        let frames = framesRequested

        for (bufferIndex, audioBuffer) in buffers.enumerated() {
            guard let dest = audioBuffer.mData else { continue }
            let destPtr = dest.assumingMemoryBound(to: Float32.self)
            let channel = min(bufferIndex, channels - 1)
            for frame in 0..<frames {
                destPtr[frame] = src[frame * channels + channel]
            }
            buffers[bufferIndex].mDataByteSize = UInt32(frames * MemoryLayout<Float32>.size)
        }

        return noErr
    }

    nonisolated private func updateRawLevels(from audioData: UnsafeMutableRawPointer, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        let samples = audioData.assumingMemoryBound(to: Float32.self)
        let minDB: Float = -60
        let epsilon: Float = 1e-7

        func normalizeRMS(_ rms: Float) -> Float {
            let db = 20 * log10f(max(rms, epsilon))
            let clampedDB = max(minDB, min(0, db))
            return (clampedDB - minDB) / (0 - minDB)
        }

        if channels == 1 {
            var sumSquares: Float = 0
            for i in 0..<frames {
                let s = samples[i]
                sumSquares += s * s
            }
            let rms = sqrtf(sumSquares / Float(frames))
            let normalized = normalizeRMS(rms)
            rawLevelLeft = normalized
            rawLevelRight = normalized
            return
        }

        var sumSquaresL: Float = 0
        var sumSquaresR: Float = 0
        for frame in 0..<frames {
            let base = frame * channels
            let l = samples[base]
            let r = samples[base + 1]
            sumSquaresL += l * l
            sumSquaresR += r * r
        }

        let rmsL = sqrtf(sumSquaresL / Float(frames))
        let rmsR = sqrtf(sumSquaresR / Float(frames))
        rawLevelLeft = normalizeRMS(rmsL)
        rawLevelRight = normalizeRMS(rmsR)
    }
}

@inline(__always)
private func smoothMeter(current: Float, target: Float, attack: Float, release: Float) -> Float {
    let alpha = target > current ? attack : release
    return current * alpha + target * (1 - alpha)
}

private func deviceSampleRate(deviceID: AudioDeviceID) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var sampleRate = Double(44_100)
    var dataSize = UInt32(MemoryLayout<Double>.size)

    try checkStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate),
        "Get device sample rate"
    )

    return sampleRate
}

private func deviceChannelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    try checkStatus(
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
        "Get stream configuration size"
    )

    let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { bufferListPointer.deallocate() }

    try checkStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer),
        "Get stream configuration"
    )

    let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.reduce(0) { $0 + $1.mNumberChannels }
}

private let inputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let engine = Unmanaged<InputToOutputMonitorEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let inputUnit = engine.inputUnit else { return noErr }
    return engine.handleInput(unit: inputUnit, flags: ioActionFlags, timeStamp: inTimeStamp, busNumber: inBusNumber, frameCount: inNumberFrames)
}

private let outputRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    guard let ioData else { return noErr }
    let engine = Unmanaged<InputToOutputMonitorEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.renderOutput(ioData: ioData, frameCount: inNumberFrames)
}
