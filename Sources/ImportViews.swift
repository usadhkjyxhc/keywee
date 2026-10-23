import SwiftUI
import UniformTypeIdentifiers

struct Candidate: Identifiable, Hashable {
    let host: String      // normalized (lower case, no scheme, no trailing slash)
    let title: String
    var id: String { host }
}

// MARK: - Parsing: saved kiwisdr.com/public page, pasted lines or any HTML with links

enum ReceiverImport {
    static func candidates(from raw: String) -> [Candidate] {
        var text = raw
        let plain = text.contains("<div class='cl-entry") || text.contains("<div class=\"cl-entry")
        if !plain, text.contains("&lt;"), text.contains("cl-entry") {
            // page saved from "view source": tags are escaped and wrapped in <span>s
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            text = unescape(text)
        }
        if text.contains("cl-entry") {
            let c = fromKiwiPage(text)
            if !c.isEmpty { return c }
        }
        if text.contains("<a "), text.lowercased().contains("href") {
            let c = fromLinks(text)
            if !c.isEmpty { return c }
        }
        return fromLines(text)
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func strip(_ s: String) -> String {
        unescape(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func field(_ key: String, in e: String) -> String? {
        guard let r = e.range(of: "<!-- \(key)=") else { return nil }
        let rest = e[r.upperBound...]
        guard let end = rest.range(of: " -->") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// kiwisdr.com/public: one block per receiver with the link and the name in comments.
    /// Works for single or double quotes (browsers rewrite quotes when they save a page).
    private static func fromKiwiPage(_ html: String) -> [Candidate] {
        let text = html.replacingOccurrences(of: "<div class=\"cl-entry", with: "<div class='cl-entry")
        var out: [Candidate] = []
        var seen = Set<String>()
        for e in text.components(separatedBy: "<div class='cl-entry").dropFirst() {
            guard let r = e.range(of: "<a href=") else { continue }
            var rest = e[r.upperBound...]
            guard let q = rest.first, q == "'" || q == "\"" else { continue }
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: q) else { continue }
            let host = Atlas.normalize(String(rest[..<end]))
            guard !host.isEmpty, seen.insert(host).inserted else { continue }
            let name = strip(field("name", in: e) ?? "")
            out.append(Candidate(host: host, title: name.isEmpty ? host : name))
        }
        return out
    }

    /// Any HTML page: every link to a receiver, with the link text as the title.
    private static func fromLinks(_ html: String) -> [Candidate] {
        guard let rx = try? NSRegularExpression(
            pattern: #"<a\s[^>]*?href=["'](https?://[^"']+)["'][^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = html as NSString
        var out: [Candidate] = []
        var seen = Set<String>()
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var url = ns.substring(with: m.range(at: 1))
            if let slash = url.range(of: "://") {
                let after = url[slash.upperBound...]
                if let p = after.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                    url = String(url[..<p])
                }
            }
            let host = Atlas.normalize(url)
            if host.contains("kiwisdr.com"), !host.contains(".proxy.kiwisdr.com") { continue }
            guard !host.isEmpty, seen.insert(host).inserted else { continue }
            let name = strip(ns.substring(with: m.range(at: 2)))
            out.append(Candidate(host: host, title: name.isEmpty ? host : name))
        }
        return out
    }

    private static let hostRegex = try! NSRegularExpression(
        pattern: #"(?:https?://)?((?:\d{1,3}\.){3}\d{1,3}(?::\d{2,5})?|[A-Za-z0-9][A-Za-z0-9\-\.]*\.[A-Za-z]{2,}(?::\d{2,5})?)(?:/\S*)?"#)

    /// One receiver per line: "host:port", "https://host:port/", "Name, host:port", "host:port Name" ...
    /// A name on the line before a bare link is used as its title.
    private static func fromLines(_ text: String) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        var pending: String?
        let trim = CharacterSet(charactersIn: " \t|,;:-–—\"'()[]<>")
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { pending = nil; continue }
            let ns = line as NSString
            if let m = hostRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let host = Atlas.normalize(ns.substring(with: m.range(at: 1)))
                var title = ns.replacingCharacters(in: m.range, with: "").trimmingCharacters(in: trim)
                if title.isEmpty, let p = pending, p.count < 120 { title = p }
                pending = nil
                guard !host.isEmpty, seen.insert(host).inserted else { continue }
                out.append(Candidate(host: host, title: title.isEmpty ? host : title))
            } else {
                pending = line
            }
        }
        return out
    }
}

// MARK: - Pick receivers and add them to the Atlas

struct ImportPicker: View {
    let title: String
    let candidates: [Candidate]
    let existing: Set<String>          // normalized hosts that are already in the Atlas
    let onAdd: ([Candidate]) -> Void
    let done: () -> Void

    @State private var query = ""
    @State private var selected = Set<String>()

    private var filtered: [Candidate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.title.lowercased().contains(q) || $0.host.contains(q) }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Text("No matches.").font(.footnote).foregroundColor(.secondary).listRowBackground(rowBG)
            }
            ForEach(filtered) { c in
                let added = existing.contains(c.host)
                let on = selected.contains(c.host)
                Button {
                    if added { return }
                    if on { selected.remove(c.host) } else { selected.insert(c.host) }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(on ? amber : amber.opacity(0.14))
                            Image(systemName: on ? "checkmark" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(on ? .black : amber)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.body.weight(.medium)).foregroundColor(.primary).lineLimit(2)
                            Text(c.host).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if added { Text("In directory").font(.caption2).foregroundColor(.secondary) }
                    }
                    .padding(.vertical, 2)
                    .opacity(added ? 0.45 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(rowBG)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search name or address")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                    onAdd(candidates.filter { selected.contains($0.id) })
                    done()
                }
                .disabled(selected.isEmpty)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Select all") {
                    filtered.filter { !existing.contains($0.host) }.forEach { selected.insert($0.host) }
                }
                Spacer()
                Button("Clear") { selected.removeAll() }
            }
        }
    }
}

// MARK: - Import from a file, the clipboard or typed text

struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showFiles = false
    @State private var found: [Candidate] = []
    @State private var known = Set<String>()
    @State private var showPicker = false
    @State private var info = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showFiles = true } label: { Label("Choose file …", systemImage: "doc") }
                    Button {
                        if let s = UIPasteboard.general.string, !s.isEmpty { process(s) }
                        else { info = "The clipboard is empty." }
                    } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                } header: { Text("Source") } footer: {
                    Text("A saved kiwisdr.com/public page (.html), any text file or a copied list works. You then pick which receivers to add.")
                }
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 150)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("Or type a list") } footer: {
                    Text("One receiver per line, for example:\nDutch loop, pb8w.proxy.kiwisdr.com\ng8ure.ddns.net:8071")
                }
                if !info.isEmpty {
                    Section { Text(info).foregroundColor(.orange) }
                }
            }
            .navigationTitle("Import receivers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { process(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationDestination(isPresented: $showPicker) {
                ImportPicker(title: "\(found.count) found", candidates: found, existing: known,
                             onAdd: { list in
                                 Atlas.addMany(list.map { (title: $0.title, host: $0.host) })
                             },
                             done: { dismiss() })
            }
        }
        // attached to the stack (not to the Form) and any file type is accepted
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error):
                info = "Could not open the file: \(error.localizedDescription)"
            case .success(let urls):
                guard let url = urls.first else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: url) else {
                    info = "That file could not be read."
                    return
                }
                let s = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
                process(s)
            }
        }
        .tint(amber)
    }

    private func process(_ raw: String) {
        let c = ReceiverImport.candidates(from: raw)
        if c.isEmpty {
            info = "No receivers found (read \(raw.count) characters)."
            return
        }
        info = ""
        found = c
        known = Set(Atlas.load().map { Atlas.normalize($0.host) })
        // let the file picker finish closing before pushing the next screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showPicker = true }
    }
}
