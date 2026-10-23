import SwiftUI

/// Small sheet to change a title (favorites, ...).
struct RenameSheet: View {
    let heading: String
    let footer: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @FocusState private var focused: Bool

    init(heading: String, title: String, footer: String, onSave: @escaping (String) -> Void) {
        self.heading = heading; self.footer = footer; self.onSave = onSave
        _title = State(initialValue: title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).focused($focused)
                } footer: { Text(footer) }
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(title.trimmingCharacters(in: .whitespaces)); dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .tint(amber)
        .presentationDetents([.height(250)])
    }
}

/// Favorite receivers (main menu, star icon).
struct FavoritesView: View {
    @ObservedObject private var library = Library.shared
    @AppStorage("lastReceiverHost") private var lastHost = ""
    @State private var editFav: FavoriteReceiver?

    var body: some View {
        List {
            if library.favoriteReceivers.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "star").font(.system(size: 34)).foregroundColor(amber)
                        Text("No favorite receivers yet").font(.headline)
                        Text("While listening, tap the star next to the volume slider to favorite the receiver.")
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(library.favoriteReceivers) { f in
                        let last = Atlas.normalize(f.host) == Atlas.normalize(lastHost)
                        NavigationLink { RadioView(host: f.host, title: f.title) } label: {
                            ReceiverRow(icon: "star.fill", title: f.title,
                                        subtitle: last ? "\(f.host) · last listened" : f.host, onAir: last)
                        }
                        .listRowBackground(rowBG)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { library.removeFavorite(host: f.host) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editFav = f } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                        }
                    }
                } footer: { Text("Swipe left to edit or delete.") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editFav) { f in
            RenameSheet(heading: "Edit favorite", title: f.title, footer: f.host) { t in
                library.setFavorite(host: f.host, title: t)
            }
        }
    }
}
