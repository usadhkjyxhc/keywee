import Foundation

/// A receiver in the Receiver Atlas.
struct SavedReceiver: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var host: String
}

/// A favorite receiver (with its own title).
struct FavoriteReceiver: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var host: String
}

struct LogEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var freq: Double      // kHz
    var mode: String
    var date: Date
    var receiver: String
    var note: String
    var host: String? = nil            // receiver address, so the entry can be reopened
    var receiverTitle: String? = nil
}

/// Values captured at the moment the user taps "Log current station".
struct LogDraft: Identifiable {
    let id = UUID()
    let freq: Double
    let mode: String
    let receiver: String
    let date: Date
    var host: String = ""
    var receiverTitle: String? = nil
}

enum GMT {
    private static func make(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "GMT")
        d.dateFormat = f
        return d
    }
    private static let dateFmt = make("yyyy-MM-dd")
    private static let timeFmt = make("HH:mm:ss")
    static func date(_ d: Date) -> String { dateFmt.string(from: d) }
    static func time(_ d: Date) -> String { timeFmt.string(from: d) }
    static func stamp(_ d: Date) -> String { "\(date(d)) \(time(d).prefix(5)) GMT" }
}

/// The Receiver Atlas: every receiver the user imported or added. Stored as JSON in UserDefaults.
enum Atlas {
    static let key = "savedReceivers"

    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "ws://"] where t.lowercased().hasPrefix(p) { t.removeFirst(p.count) }
        while t.hasSuffix("/") { t.removeLast() }
        return t.lowercased()
    }

    static func load() -> [SavedReceiver] {
        guard let s = UserDefaults.standard.string(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedReceiver].self, from: Data(s.utf8))) ?? []
    }

    static func save(_ list: [SavedReceiver]) {
        let d = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
        UserDefaults.standard.set(String(decoding: d, as: UTF8.self), forKey: key)
    }

    static func title(for host: String) -> String? {
        let h = normalize(host)
        return load().first { normalize($0.host) == h }?.title
    }

    /// Adds receivers (title, host). Hosts that are already in the Atlas are skipped.
    /// Returns how many were added.
    @discardableResult
    static func addMany(_ items: [(title: String, host: String)]) -> Int {
        var l = load()
        var known = Set(l.map { normalize($0.host) })
        var added = 0
        for item in items {
            let h = normalize(item.host)
            guard !h.isEmpty, known.insert(h).inserted else { continue }
            let t = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            l.append(SavedReceiver(title: t.isEmpty ? h : t, host: h))
            added += 1
        }
        if added > 0 { save(l) }
        return added
    }

    /// Makes sure the receiver exists in the Atlas; a new entry is titled with its address.
    static func ensure(host: String) {
        let h = normalize(host)
        addMany([(title: h, host: h)])
    }
}

/// Favorite receivers and the logbook, stored as JSON in UserDefaults.
final class Library: ObservableObject {
    static let shared = Library()

    @Published var favoriteReceivers: [FavoriteReceiver] {
        didSet { Self.save(favoriteReceivers, "keywee_favreceivers") }
    }
    @Published var log: [LogEntry] { didSet { Self.save(log, "keywee_log") } }

    private init() {
        favoriteReceivers = Self.load("keywee_favreceivers")
        log = Self.load("keywee_log")
    }

    func favorite(for host: String) -> FavoriteReceiver? {
        favoriteReceivers.first { $0.host == host }
    }

    func setFavorite(host: String, title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        let name = t.isEmpty ? host : t
        if let i = favoriteReceivers.firstIndex(where: { $0.host == host }) {
            favoriteReceivers[i].title = name
        } else {
            favoriteReceivers.insert(FavoriteReceiver(title: name, host: host), at: 0)
        }
    }

    func removeFavorite(host: String) {
        favoriteReceivers.removeAll { $0.host == host }
    }

    var exportText: String {
        log.map { e in
            [GMT.stamp(e.date), String(format: "%.3f kHz", e.freq), e.mode.uppercased(),
             e.title, e.receiver, e.host ?? "", e.note].filter { !$0.isEmpty }.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private static func load<T: Decodable>(_ key: String) -> [T] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: d)) ?? []
    }

    private static func save<T: Encodable>(_ items: [T], _ key: String) {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}
