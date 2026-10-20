import Foundation

/// A contiguous, one-to-one group of channels. Channel numbers are zero-based internally.
struct InterfaceChannelSelection: Codable, Equatable, Sendable {
    var inputStart = 0
    var outputStart = 0
    var count = 2

    func isValid(inputCount: Int, outputCount: Int) -> Bool {
        count > 0 && inputStart >= 0 && outputStart >= 0
            && count <= inputCount && count <= outputCount
            && inputStart <= inputCount - count && outputStart <= outputCount - count
    }

    var inputMap: [Int32] {
        guard count > 0, inputStart >= 0, count <= Int(Int32.max), inputStart <= Int(Int32.max) - count else { return [] }
        return (inputStart..<(inputStart + count)).map(Int32.init)
    }

    func outputMap(hardwareChannels: Int) -> [Int32] {
        guard hardwareChannels > 0, count > 0, outputStart >= 0, count <= hardwareChannels,
              outputStart <= hardwareChannels - count else { return [] }
        var map = Array(repeating: Int32(-1), count: hardwareChannels)
        for channel in 0..<count { map[outputStart + channel] = Int32(channel) }
        return map
    }

    var inputText: String { channelText(start: inputStart) }
    var outputText: String { channelText(start: outputStart) }
    var summary: String { "Inputs \(inputText) → Outputs \(outputText)" }

    private func channelText(start: Int) -> String {
        count == 1 ? "\(start + 1)" : "\(start + 1)–\(start + count)"
    }
}
