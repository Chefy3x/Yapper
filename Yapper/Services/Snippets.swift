import Foundation
import Combine

/// Say the trigger, get the text: "my calendar link" types the whole URL. Wispr Flow's snippets.
struct Snippet: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var trigger: String
    var expansion: String
    var createdAt: Date = Date()
    /// Times it has expanded in a dictation.
    var uses: Int = 0
}

/// The user's snippets, as JSON in Application Support/Yapper. Never leaves the machine.
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? DictationHistoryStore.defaultDirectory().appendingPathComponent("snippets.json")
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        }
    }

    enum EditError: LocalizedError, Equatable {
        case emptyTrigger, emptyExpansion, duplicateTrigger(String)
        var errorDescription: String? {
            switch self {
            case .emptyTrigger: "Say-this needs at least one word."
            case .emptyExpansion: "Add the text to type."
            case .duplicateTrigger(let t): "“\(t)” is already a snippet."
            }
        }
    }

    @discardableResult
    func add(trigger: String, expansion: String) throws -> Snippet {
        let t = try validTrigger(trigger, excluding: nil)
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.emptyExpansion }
        let snippet = Snippet(trigger: t, expansion: expansion)
        snippets.insert(snippet, at: 0)
        save()
        return snippet
    }

    func update(_ id: UUID, trigger: String, expansion: String) throws {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        let t = try validTrigger(trigger, excluding: id)
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.emptyExpansion }
        snippets[i].trigger = t
        snippets[i].expansion = expansion
        save()
    }

    func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func noteUsed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { if let i = snippets.firstIndex(where: { $0.id == id }) { snippets[i].uses += 1 } }
        save()
    }

    /// Runs this dictation's text through the snippets, counting the ones that fired.
    func expand(_ text: String) -> String {
        let result = SnippetExpander.expand(text, snippets: snippets)
        noteUsed(result.used)
        return result.text
    }

    private func validTrigger(_ raw: String, excluding id: UUID?) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SnippetExpander.words(t)
        guard !key.isEmpty else { throw EditError.emptyTrigger }
        if snippets.contains(where: { $0.id != id && SnippetExpander.words($0.trigger) == key }) {
            throw EditError.duplicateTrigger(t)
        }
        return t
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) { try? data.write(to: url, options: .atomic) }
    }
}

/// Pure text rules for snippets, apart from the store so tests can drive them directly.
enum SnippetExpander {

    /// A trigger as the words it's made of, lowercased: "My Calendar-link!" → ["my", "calendar", "link"].
    /// What the speech model writes around the words (case, commas, a full stop) never matters.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Replaces every spoken trigger with its text. A dictation that is nothing but the trigger
    /// becomes exactly the snippet, without the full stop the speech model adds; inside a
    /// sentence the snippet goes in where the trigger was. Longest trigger first, so
    /// "my work email" wins over "my email".
    static func expand(_ text: String, snippets: [Snippet]) -> (text: String, used: [UUID]) {
        let candidates = snippets
            .map { (snippet: $0, words: words($0.trigger)) }
            .filter { !$0.words.isEmpty && !$0.snippet.expansion.isEmpty }
            .sorted { $0.words.count > $1.words.count }
        guard !candidates.isEmpty else { return (text, []) }

        let spoken = words(text)
        for c in candidates where c.words == spoken {
            return (c.snippet.expansion, [c.snippet.id])
        }

        // Each match becomes a private-use marker first, so a snippet's own text is never
        // searched for the shorter triggers that run after it.
        var out = text
        var used: [(id: UUID, marker: String, expansion: String)] = []
        for c in candidates {
            let body = c.words.map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "[\\s,;:.\\-–—]+")
            let pattern = "(?<![\\p{L}\\p{N}'])" + body + "(?![\\p{L}\\p{N}'])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            guard regex.firstMatch(in: out, range: range) != nil else { continue }
            let marker = "\u{E000}\(used.count)\u{E001}"
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: marker)
            used.append((c.snippet.id, marker, c.snippet.expansion))
        }
        for u in used { out = out.replacingOccurrences(of: u.marker, with: u.expansion) }
        return (out, used.map(\.id))
    }
}
