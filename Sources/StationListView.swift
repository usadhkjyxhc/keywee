import SwiftUI

struct StationListView: View {
    struct EditorTarget: Identifiable {
        let id = UUID()
        var existing: SavedReceiver?
        var title: String
        var host: String
    }

    @AppStorage("savedReceivers") private var savedJSON = ""
    @State private var editor: EditorTarget?
    @State private var showImport = false

    private var atlasCount: Int {
        (try? JSONDecoder().decode([SavedReceiver].self, from: Data(savedJSON.utf8)))?.count ?? 0
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { AtlasView() } label: {
                        ActionRow(icon: "globe", title: "Receiver Atlas",
                                  subtitle: atlasCount == 0 ? "Your imported receivers live here"
                                                            : "\(atlasCount) receivers")
                    }
                    .listRowBackground(rowBG)
                    Button { editor = EditorTarget(existing: nil, title: "", host: "") } label: {
                        ActionRow(icon: "plus", title: "Add receiver", subtitle: "A single receiver by host:port")
                    }
                    .listRowBackground(rowBG)
                    Button { showImport = true } label: {
                        ActionRow(icon: "square.and.arrow.down", title: "Import from file or text",
                                  subtitle: "Saved kiwisdr.com page, text file or pasted list",
                                  trailing: "chevron.right")
                    }
                    .listRowBackground(rowBG)
                } header: { Text("Receivers") }

                Section {
                    Link(destination: URL(string: "http://rx.kiwisdr.com")!) {
                        ActionRow(icon: "map", title: "Receiver map",
                                  subtitle: "rx.kiwisdr.com · opens in browser", trailing: "arrow.up.right")
                    }
                    .listRowBackground(rowBG)
                    Link(destination: URL(string: "https://short-wave.info")!) {
                        ActionRow(icon: "calendar", title: "Broadcast schedules",
                                  subtitle: "short-wave.info · opens in browser", trailing: "arrow.up.right")
                    }
                    .listRowBackground(rowBG)
                } header: { Text("On the web") }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { GMTClock() }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    NavigationLink { LogbookView() } label: { Image(systemName: "book") }
                    NavigationLink { FavoritesView() } label: { Image(systemName: "star") }
                }
            }
            .sheet(item: $editor) { t in
                ReceiverEditor(target: t) { title, host in
                    Atlas.addMany([(title: title, host: host)])
                }
            }
            .sheet(isPresented: $showImport) { ImportSheet() }
        }
        .tint(amber)
    }
}

/// Add / edit one receiver (name + address).
struct ReceiverEditor: View {
    let target: StationListView.EditorTarget
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var host: String

    init(target: StationListView.EditorTarget, onSave: @escaping (String, String) -> Void) {
        self.target = target; self.onSave = onSave
        _title = State(initialValue: target.title)
        _host = State(initialValue: target.host)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Dutch loop antenna", text: $title)
                } header: { Text("Name") } footer: {
                    Text("Shown in your lists instead of the address.")
                }
                Section {
                    TextField("host:port", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: { Text("Address") } footer: {
                    Text("For example g8ure.ddns.net:8071. Pasted links are cleaned up automatically.")
                }
            }
            .navigationTitle(target.existing == nil ? "Add receiver" : "Edit receiver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title.trimmingCharacters(in: .whitespaces), Atlas.normalize(host))
                        dismiss()
                    }
                    .disabled(Atlas.normalize(host).isEmpty)
                }
            }
        }
        .tint(amber)
        .presentationDetents([.medium])
    }
}
