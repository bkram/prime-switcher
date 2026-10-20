import CoreAudio

/// Small seams around hardware so lifecycle tests never capture or play audio.
@MainActor
protocol InterfaceRouteRuntime: AnyObject {
    func start(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID, channels: InterfaceChannelSelection)
    func stop()
}

extension InputToOutputMonitorEngine: InterfaceRouteRuntime {}

@MainActor
protocol AppRouteRuntime: AnyObject {
    var isRunning: Bool { get }
    var failureMessage: String? { get }
    func start(application: AppAudioSource, outputDevice: InputToOutputDevice, outputChannels: [Int])
    func stop()
}

extension RouteRunner: AppRouteRuntime {
    func start(application: AppAudioSource, outputDevice: InputToOutputDevice, outputChannels: [Int]) {
        start(application: application, outputDevice: outputDevice, outputChannels: outputChannels, mutesApplication: true)
    }
}
