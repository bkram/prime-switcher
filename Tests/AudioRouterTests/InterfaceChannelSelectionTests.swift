import Testing
@testable import Input_to_Output_Monitor

struct InterfaceChannelSelectionTests {
    @Test func monoCanUseAnyInputAndOutput() {
        let selection = InterfaceChannelSelection(inputStart: 3, outputStart: 5, count: 1)
        #expect(selection.isValid(inputCount: 8, outputCount: 8))
        #expect(selection.inputMap == [3])
        #expect(selection.outputMap(hardwareChannels: 8) == [-1, -1, -1, -1, -1, 0, -1, -1])
        #expect(selection.summary == "Inputs 4 → Outputs 6")
    }

    @Test func stereoMapsSelectedPairWithoutLeakingToOtherOutputs() {
        let selection = InterfaceChannelSelection(inputStart: 2, outputStart: 4, count: 2)
        #expect(selection.isValid(inputCount: 16, outputCount: 16))
        #expect(selection.inputMap == [2, 3])
        #expect(selection.outputMap(hardwareChannels: 8) == [-1, -1, -1, -1, 0, 1, -1, -1])
        #expect(selection.summary == "Inputs 3–4 → Outputs 5–6")
    }

    @Test func multichannelGroupsMapOneToOne() {
        let selection = InterfaceChannelSelection(inputStart: 4, outputStart: 8, count: 4)
        #expect(selection.isValid(inputCount: 16, outputCount: 16))
        #expect(selection.inputMap == [4, 5, 6, 7])
        #expect(selection.outputMap(hardwareChannels: 16) == [-1, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, -1, -1, -1, -1])
    }

    @Test func allChannelsAreSupported() {
        let selection = InterfaceChannelSelection(count: 16)
        #expect(selection.isValid(inputCount: 16, outputCount: 16))
        #expect(selection.inputMap == (0..<16).map(Int32.init))
        #expect(selection.outputMap(hardwareChannels: 16) == selection.inputMap)
    }

    @Test func invalidSelectionsAreRejected() {
        #expect(!InterfaceChannelSelection(count: 0).isValid(inputCount: 2, outputCount: 2))
        #expect(!InterfaceChannelSelection(inputStart: -1).isValid(inputCount: 2, outputCount: 2))
        #expect(!InterfaceChannelSelection(outputStart: -1).isValid(inputCount: 2, outputCount: 2))
        #expect(!InterfaceChannelSelection(inputStart: 1, count: 2).isValid(inputCount: 2, outputCount: 8))
        #expect(!InterfaceChannelSelection(outputStart: 7, count: 2).isValid(inputCount: 8, outputCount: 8))
        #expect(!InterfaceChannelSelection(count: 4).isValid(inputCount: 16, outputCount: 2))
        #expect(InterfaceChannelSelection(outputStart: 7, count: 2).outputMap(hardwareChannels: 8).isEmpty)
    }
}
