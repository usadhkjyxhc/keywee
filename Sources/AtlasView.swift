import SwiftUI

/// The Receiver Atlas: every receiver the user imported or added.
struct AtlasView: View {
    @AppStorage("savedReceivers") private var savedJSON = ""
    @AppStorage("lastReceiverHost") private var lastHost = ""
    @ObservedObject private var library = Library.shared
    @State private var query = ""
    @State private var editor: StationListView.EditorTarget?
    @State private var showImport = false
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var confirmDelete = false

    private var saved: [SavedReceiver] {
        (try? JSONDecoder().decode([SavedReceiver].self, from: Data(savedJSON.utf8))) ?? []
    }

    private var shown: [SavedReceiver] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let l = q.isEmpty ? saved : saved.filter { $0.title.lowercased().contains(q) || $0.host.contains(q) }
        return l.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if saved.isEmpty {
                Section { emptyState }.listRowBackground(Color.clear)
            } else {
                Section {
                    if shown.isEmpty {
                        Text("No matches.").font(.footnote).foregroundColor(.secondary).listRowBackground(rowBG)
                    }
                    ForEach(shown) { r in
                        if selecting { selectRow(r) } else { normalRow(r) }
                    }
                } header: {
                    Text(selecting ? "\(selected.count) of \(shown.count) selected" : "\(shown.count) receivers")
                } footer: {
                    Text(selecting ? "Tap receivers to select them. Search first to select only the matches."
                                   : "Swipe left to edit or delete.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Receiver Atlas")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search receivers")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if selecting {
                    Button("Done") { selecting = false; selected.removeAll() }
                } else {
                    if !saved.isEmpty {
                        Button("Select") { selecting = true }
                    }
                    Menu {
                        Button { editor = StationListView.EditorTarget(existing: nil, title: "", host: "") } label: {
                            Label("Add receiver", systemImage: "plus")
                        }
                        Button { showImport = true } label: {
                            Label("Import from file or text", systemImage: "square.and.arrow.down")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if selecting {
                    Button("Select all") { shown.forEach { selected.insert($0.id) } }
                    Spacer()
                    Button("Unselect all") { selected.removeAll() }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(selected.isEmpty ? "Delete" : "Delete (\(selected.count))")
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .toolbar(selecting ? .visible : .hidden, for: .bottomBar)
        .confirmationDialog("Delete \(selected.count) receivers from the Atlas?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(selected.count)", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your favorites and logbook entries are not affected.")
        }
        .sheet(item: $editor) { t in
            ReceiverEditor(target: t) { title, host in
                if let old = t.existing {
                    var l = Atlas.load()
                    if let i = l.firstIndex(where: { $0.id == old.id }) {
                        let h = Atlas.normalize(host)
                        l[i].title = title.isEmpty ? h : title
                        l[i].host = h
                        Atlas.save(l)
                    }
                } else {
                    Atlas.addMany([(title: title, host: host)])
                }
            }
        }
        .sheet(isPresented: $showImport) { ImportSheet() }
    }

    // MARK: Rows

    @ViewBuilder private func normalRow(_ r: SavedReceiver) -> some View {
        let last = Atlas.normalize(r.host) == Atlas.normalize(lastHost)
        NavigationLink { RadioView(host: r.host, title: r.title) } label: {
            ReceiverRow(icon: "antenna.radiowaves.left.and.right", title: r.title,
                        subtitle: last ? "\(r.host) · last listened" : r.host,
                        favorite: library.favorite(for: r.host) != nil, onAir: last)
        }
        .listRowBackground(rowBG)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { remove(r) } label: { Label("Delete", systemImage: "trash") }
            Button { editor = StationListView.EditorTarget(existing: r, title: r.title, host: r.host) } label: {
                Label("Edit", systemImage: "pencil")
            }.tint(.gray)
        }
        .contextMenu {
            Button {
                if library.favorite(for: r.host) == nil {
                    library.setFavorite(host: r.host, title: r.title)
                } else {
                    library.removeFavorite(host: r.host)
                }
            } label: {
                Label(library.favorite(for: r.host) == nil ? "Add to favorites" : "Remove from favorites",
                      systemImage: "star")
            }
            Button { editor = StationListView.EditorTarget(existing: r, title: r.title, host: r.host) } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button { selecting = true; selected = [r.id] } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) { remove(r) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder private func selectRow(_ r: SavedReceiver) -> some View {
        let on = selected.contains(r.id)
        let last = Atlas.normalize(r.host) == Atlas.normalize(lastHost)
        Button {
            if on { selected.remove(r.id) } else { selected.insert(r.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(on ? amber : .secondary)
                ReceiverRow(icon: "antenna.radiowaves.left.and.right", title: r.title,
                            subtitle: last ? "\(r.host) · last listened" : r.host,
                            favorite: library.favorite(for: r.host) != nil, onAir: last)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(on ? amber.opacity(0.12) : rowBG)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe").font(.system(size: 34)).foregroundColor(amber)
            Text("Your atlas is empty").font(.headline)
            Text("Import a list of receivers from a file or the clipboard, or add a single one by host:port.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button { showImport = true } label: {
                Text("Import list").font(.body.weight(.semibold)).foregroundColor(.black)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(amber, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { editor = StationListView.EditorTarget(existing: nil, title: "", host: "") } label: {
                Text("Add receiver").font(.subheadline.weight(.medium)).foregroundColor(amber)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: Actions

    private func remove(_ r: SavedReceiver) {
        Atlas.save(Atlas.load().filter { $0.id != r.id })
    }

    private func deleteSelected() {
        let ids = selected
        Atlas.save(Atlas.load().filter { !ids.contains($0.id) })
        selected.removeAll()
        selecting = false
    }
}
