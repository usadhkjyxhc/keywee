import SwiftUI

// MARK: - Info about the receiver and the connection (selectable text)

struct ReceiverInfoSheet: View {
    @ObservedObject var kiwi: KiwiClient
    let host: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private typealias Section_ = (title: String, rows: [(String, String)])

    private var sections: [Section_] {
        let pb = kiwi.mode.passband
        var s: [Section_] = []
        s.append(("Receiver", [("Name", title), ("Address", host), ("Status", kiwi.status),
                               ("Playing", kiwi.isPlaying ? "yes" : "no")]))
        s.append(("Tuning", [
            ("Frequency", String(format: "%.3f kHz", kiwi.freq)),
            ("Mode", kiwi.mode.label),
            ("Passband", "\(pb.low) to \(pb.high) Hz"),
            ("Zoom", String(format: "%.1f", kiwi.zoomLevel)),
            ("Visible range", String(format: "%.3f to %.3f kHz", kiwi.viewStart, kiwi.viewStart + kiwi.viewSpan)),
            ("Signal", String(format: "%.1f dBm", kiwi.smeter))]))
        var stream: [(String, String)] = [
            ("Audio packets", "\(kiwi.sndCount)"),
            ("Waterfall rows", "\(kiwi.wfCount)"),
            ("Row rate", String(format: "%.1f rows/s", kiwi.wfRate)),
            ("Data rate", String(format: "%.0f kB/s", kiwi.dataRate))]
        if !kiwi.lastMsg.isEmpty { stream.append(("Last server message", kiwi.lastMsg)) }
        if !kiwi.lastClose.isEmpty { stream.append(("Last disconnect", kiwi.lastClose)) }
        s.append(("Stream", stream))
        if !kiwi.eventLog.isEmpty {
            s.append(("Connection log (newest first)", kiwi.eventLog.reversed().map { e in
                let p = e.split(separator: " ", maxSplits: 1)
                return (p.first.map(String.init) ?? "", p.count > 1 ? String(p[1]) : "")
            }))
        }
        if !kiwi.serverInfo.isEmpty {
            s.append(("Reported by the receiver", kiwi.serverInfo.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        }
        return s
    }

    private var plainText: String {
        sections.map { sec in
            sec.title + "\n" + sec.rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, sec in
                    Section(sec.title) {
                        ForEach(Array(sec.rows.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.0).font(.caption).foregroundColor(.secondary)
                                Text(row.1.isEmpty ? "-" : row.1).textSelection(.enabled)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
                Section {
                    Button {
                        UIPasteboard.general.string = plainText
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } footer: { Text("Touch and hold any value to select and copy it.") }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(amber)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Sleep timer

struct SleepSheet: View {
    @ObservedObject var kiwi: KiwiClient
    @Environment(\.dismiss) private var dismiss
    private let options = [15, 30, 45, 60, 90, 120]

    private func label(_ m: Int) -> String {
        if m < 60 { return "\(m) minutes" }
        if m == 60 { return "1 hour" }
        if m % 60 == 0 { return "\(m / 60) hours" }
        return "\(m / 60) h \(m % 60) min"
    }

    private func remaining(_ end: Date) -> String {
        let t = max(0, Int(end.timeIntervalSinceNow))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    var body: some View {
        NavigationStack {
            List {
                if let end = kiwi.sleepEnd {
                    Section {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack {
                                Text("Radio turns off in")
                                Spacer()
                                Text(remaining(end)).font(.system(.body, design: .monospaced)).foregroundColor(amber)
                            }
                        }
                        Button(role: .destructive) { kiwi.cancelSleep(); dismiss() } label: {
                            Label("Cancel timer", systemImage: "xmark.circle")
                        }
                    }
                }
                Section {
                    ForEach(options, id: \.self) { m in
                        Button { kiwi.startSleep(minutes: m); dismiss() } label: {
                            HStack {
                                Text(label(m)).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "moon.zzz").foregroundColor(amber)
                            }
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                        }
                    }
                } header: {
                    Text(kiwi.sleepEnd == nil ? "Turn off after" : "Change to")
                } footer: {
                    Text("The volume fades out during the last 20 seconds, then the radio disconnects.")
                }
            }
            .navigationTitle("Sleep timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(amber)
        .presentationDetents([.medium, .large])
    }
}
