import SwiftUI

// MARK: - Logbook row

private struct LogRow: View {
    let e: LogEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(e.title.isEmpty ? String(format: "%.3f kHz", e.freq) : e.title)
                .font(.body.weight(.medium)).foregroundColor(.primary)
            Text(String(format: "%.3f kHz · %@ · ", e.freq, e.mode.uppercased()) + GMT.stamp(e.date))
                .font(.caption).foregroundColor(.secondary)
            Text(e.receiver).font(.caption2).foregroundColor(.secondary)
            if !e.note.isEmpty { Text(e.note).font(.caption).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Library sheet in the radio (favorite receivers + logbook)

struct LibrarySheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case favorites = "Favorites", logbook = "Logbook"
        var id: String { rawValue }
    }

    let host: String
    let receiverName: String
    let freq: Double
    let mode: RadioMode
    let onOpenFavorite: (FavoriteReceiver) -> Void
    let onOpenLog: (LogEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = Library.shared
    @State private var tab = Tab.favorites
    @State private var showFav = false
    @State private var logDraft: LogDraft?
    @State private var editFav: FavoriteReceiver?
    @State private var editLog: LogEntry?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                List {
                    if tab == .favorites { favoritesContent } else { logContent }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if tab == .logbook && !library.log.isEmpty { ShareLink(item: library.exportText) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showFav) { FavoriteReceiverSheet(host: host, defaultTitle: receiverName) }
            .sheet(item: $logDraft) { d in LogEntrySheet(draft: d) }
            .sheet(item: $editFav) { f in
                RenameSheet(heading: "Edit favorite", title: f.title, footer: f.host) { t in
                    library.setFavorite(host: f.host, title: t)
                }
            }
            .sheet(item: $editLog) { e in LogEditSheet(entry: e) }
        }
        .tint(amber)
        .presentationDetents([.medium, .large])
    }

    /// Large tap targets.
    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundColor(tab == t ? .black : .primary)
                        .background(tab == t ? amber : Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var favoritesContent: some View {
        Section {
            let fav = library.favorite(for: host)
            Button { showFav = true } label: {
                Label(fav == nil ? "Save “\(receiverName)”" : "Edit “\(fav?.title ?? receiverName)”",
                      systemImage: fav == nil ? "star" : "star.fill")
                    .font(.body.weight(.medium))
            }
        } footer: {
            Text("Favorites are receivers, not frequencies.")
        }
        Section {
            if library.favoriteReceivers.isEmpty {
                Text("No favorites yet.").font(.footnote).foregroundColor(.secondary)
            }
            ForEach(library.favoriteReceivers) { f in
                Button { onOpenFavorite(f); dismiss() } label: {
                    ReceiverRow(icon: "star.fill", title: f.title,
                                subtitle: f.host == host ? "\(f.host) · listening now" : f.host)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { library.removeFavorite(host: f.host) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { editFav = f } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                }
            }
        } footer: {
            if !library.favoriteReceivers.isEmpty { Text("Tap a favorite to listen there. Swipe left to edit or delete.") }
        }
    }

    @ViewBuilder private var logContent: some View {
        Section {
            Button {
                logDraft = LogDraft(freq: freq, mode: mode.rawValue, receiver: receiverName, date: Date(),
                                    host: host, receiverTitle: receiverName)
            } label: {
                Label("Log current station", systemImage: "square.and.pencil").font(.body.weight(.medium))
            }
        }
        Section {
            if library.log.isEmpty {
                Text("Nothing logged yet.").font(.footnote).foregroundColor(.secondary)
            }
            ForEach(library.log) { e in
                Button { onOpenLog(e); dismiss() } label: { LogRow(e: e) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            library.log.removeAll { $0.id == e.id }
                        } label: { Label("Delete", systemImage: "trash") }
                        Button { editLog = e } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                    }
            }
        } footer: {
            if !library.log.isEmpty {
                Text("Tap an entry to open its receiver and frequency. Swipe left to edit or delete.")
            }
        }
    }
}

// MARK: - Favorite the current receiver

struct FavoriteReceiverSheet: View {
    let host: String
    let defaultTitle: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = Library.shared
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(defaultTitle, text: $title).focused($focused)
                } header: { Text("Title") } footer: {
                    Text(host)
                }
                if library.favorite(for: host) != nil {
                    Section {
                        Button(role: .destructive) {
                            library.removeFavorite(host: host)
                            dismiss()
                        } label: { Label("Remove from favorites", systemImage: "star.slash") }
                    }
                }
            }
            .navigationTitle(library.favorite(for: host) == nil ? "Favorite receiver" : "Edit favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = title.trimmingCharacters(in: .whitespaces)
                        library.setFavorite(host: host, title: t.isEmpty ? defaultTitle : t)
                        dismiss()
                    }
                }
            }
            .onAppear {
                title = library.favorite(for: host)?.title ?? defaultTitle
                focused = true
            }
        }
        .tint(amber)
        .presentationDetents([.medium])
    }
}

// MARK: - New log entry

struct LogEntrySheet: View {
    let draft: LogDraft
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = Library.shared
    @State private var title = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Radio Romania International", text: $title)
                }
                Section("Details") {
                    LabeledContent("Frequency", value: String(format: "%.3f kHz", draft.freq))
                    LabeledContent("Mode", value: draft.mode.uppercased())
                    LabeledContent("Date", value: GMT.date(draft.date))
                    LabeledContent("Time", value: GMT.time(draft.date) + " GMT")
                    LabeledContent("Receiver", value: draft.receiver)
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Log entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.log.insert(
                            LogEntry(title: title.trimmingCharacters(in: .whitespaces),
                                     freq: draft.freq, mode: draft.mode, date: draft.date,
                                     receiver: draft.receiver, note: note,
                                     host: draft.host.isEmpty ? nil : draft.host,
                                     receiverTitle: draft.receiverTitle), at: 0)
                        dismiss()
                    }
                }
            }
        }
        .tint(amber)
        .presentationDetents([.large])
    }
}

// MARK: - Edit a log entry

struct LogEditSheet: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = Library.shared
    @State private var title: String
    @State private var freqText: String
    @State private var mode: RadioMode
    @State private var note: String

    init(entry: LogEntry) {
        self.entry = entry
        _title = State(initialValue: entry.title)
        _freqText = State(initialValue: String(format: "%.3f", entry.freq))
        _mode = State(initialValue: RadioMode(rawValue: entry.mode) ?? .am)
        _note = State(initialValue: entry.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Radio Romania International", text: $title)
                }
                Section("Details") {
                    HStack {
                        Text("Frequency")
                        Spacer()
                        TextField("kHz", text: $freqText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                        Text("kHz").foregroundColor(.secondary)
                    }
                    Picker("Mode", selection: $mode) {
                        ForEach(RadioMode.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Date", value: GMT.date(entry.date))
                    LabeledContent("Time", value: GMT.time(entry.date) + " GMT")
                    LabeledContent("Receiver", value: entry.receiver)
                    if let h = entry.host { LabeledContent("Address", value: h) }
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let i = library.log.firstIndex(where: { $0.id == entry.id }) {
                            library.log[i].title = title.trimmingCharacters(in: .whitespaces)
                            library.log[i].mode = mode.rawValue
                            library.log[i].note = note
                            let t = freqText.replacingOccurrences(of: ",", with: ".")
                                .trimmingCharacters(in: .whitespaces)
                            if let v = Double(t), v > 0 { library.log[i].freq = v < 30 ? v * 1000 : v }
                        }
                        dismiss()
                    }
                }
            }
        }
        .tint(amber)
        .presentationDetents([.large])
    }
}

// MARK: - Logbook (full screen, from the main menu)

struct LogbookView: View {
    @ObservedObject private var library = Library.shared
    @State private var target: LogEntry?
    @State private var pushed = false
    @State private var editLog: LogEntry?

    var body: some View {
        List {
            if library.log.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "book").font(.system(size: 34)).foregroundColor(amber)
                        Text("Nothing logged yet").font(.headline)
                        Text("While listening, tap the pencil button next to the volume slider to log a station.")
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(library.log) { e in
                        Button {
                            if let h = e.host, !h.isEmpty {
                                Atlas.ensure(host: h)      // makes sure the receiver is in the Atlas
                                target = e; pushed = true
                            }
                        } label: { LogRow(e: e) }
                        .buttonStyle(.plain)
                        .listRowBackground(rowBG)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                library.log.removeAll { $0.id == e.id }
                            } label: { Label("Delete", systemImage: "trash") }
                            Button { editLog = e } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                        }
                    }
                } footer: {
                    Text("Tap an entry to open its receiver and frequency. Swipe left to edit or delete.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Logbook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !library.log.isEmpty { ShareLink(item: library.exportText) }
            }
        }
        .sheet(item: $editLog) { e in LogEditSheet(entry: e) }
        .navigationDestination(isPresented: $pushed) {
            if let t = target, let h = t.host {
                RadioView(host: h, title: Atlas.title(for: h), startFreq: t.freq, startMode: t.mode)
            }
        }
    }
}
