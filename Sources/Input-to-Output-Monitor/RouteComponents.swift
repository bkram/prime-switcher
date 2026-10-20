import AppKit
import SwiftUI

/// Shared chrome keeps both routing workflows visually identical.
struct RouteSectionHeader: View {
    let title: String
    let detail: String
    let refresh: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
            Button(action: add) { Label("Add Route…", systemImage: "plus") }
        }
        .padding(16)
        Divider()
    }
}

struct RouteFooter: View {
    let text: String
    let privacyPane: String

    var body: some View {
        Divider()
        HStack(spacing: 12) {
            Text(text).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Privacy Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") {
                    NSWorkspace.shared.open(url)
                }
            }.buttonStyle(.link)
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct RouteRowLayout<Icon: View, Status: View, Meter: View>: View {
    let source: String
    let destination: String
    let detail: String
    @Binding var isEnabled: Bool
    let edit: () -> Void
    let remove: () -> Void
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var status: () -> Status
    @ViewBuilder var meter: () -> Meter

    var body: some View {
        HStack(spacing: 12) {
            icon().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(source).lineLimit(1)
                status().font(.caption).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Label(destination, systemImage: "hifispeaker").lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            meter().frame(width: 56, height: 18)
            Button("Edit…", action: edit)
            Toggle("Enable route from \(source) to \(destination)", isOn: $isEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(isEnabled ? "Turn this route off and keep its settings" : "Turn this route on")
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove route from \(source) to \(destination)")
            .accessibilityLabel("Remove route from \(source) to \(destination)")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

/// The same signal display for app taps and interface inputs.
struct AudioSignalMeter: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(index) / 12 < level ? (index > 9 ? Color.orange : Color.green) : Color.secondary.opacity(0.18))
            }
        }
        .frame(height: 14)
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int(max(0, min(1, level)) * 100)) percent")
        .help("Live audio level")
    }
}

struct AudioPassingStatus: View {
    let isPassing: Bool
    var body: some View {
        Label(isPassing ? "Audio passing" : "Waiting for audio", systemImage: isPassing ? "waveform" : "waveform.slash")
            .foregroundStyle(isPassing ? Color.green : Color.secondary)
    }
}
