import SwiftUI
import AppKit
import CoreAudio

struct ContentView: View {

    @AppStorage("AudioRouter.selectedSection") private var selectedSection = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Route type", selection: $selectedSection) {
                    Text("Interface → Interface").tag(0)
                    Text("App → Interface").tag(1)
                }.pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }.padding(20)
            Divider()
            if selectedSection == 0 { InterfaceRoutesView() } else { RoutesView() }
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 480, idealHeight: 560)
        .navigationTitle("Audio Routes")
    }

}
