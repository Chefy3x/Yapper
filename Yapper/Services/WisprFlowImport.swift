import Foundation
import SQLite3

/// Brings the words Wispr Flow has learned into Yapper's vocabulary, so switching doesn't mean
/// teaching a second app your names from scratch.
///
/// Wispr Flow keeps its dictionary in a local SQLite file. Yapper opens it read-only, takes the
/// words and their corrections, and leaves snippets alone: those are text expansions, not things
/// Whisper hears. Nothing is copied anywhere but Yapper's own vocabulary file.
enum WisprFlowImport {
    struct Entry: Equatable, Sendable {
        var phrase: String
        var replacement: String?
        /// What Wispr originally transcribed, for words learned from the user's edits.
        var observed: String?
        var isSnippet: Bool
        var isDeleted: Bool
    }

    struct Plan: Equatable, Sendable {
        var terms: [String] = []
        var rules: [Replacement] = []
        var skippedSnippets = 0
    }

    enum ImportError: LocalizedError {
        case notFound, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notFound: "Wispr Flow's dictionary isn't on this Mac"
            case .unreadable(let why): "Couldn't read Wispr Flow's dictionary: \(why)"
            }
        }
    }

    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Wispr Flow", isDirectory: true)
            .appendingPathComponent("flow.sqlite")
    }

    static var isAvailable: Bool { FileManager.default.isReadableFile(atPath: databaseURL.path) }

    // MARK: Reading

    static func readEntries(from url: URL = databaseURL) throws -> [Entry] {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ImportError.notFound }
        // Read-only, but not immutable: Wispr Flow may be running with recent words still in its
        // write-ahead log. If that can't be opened, the immutable snapshot is the fallback.
        var db: OpaquePointer?
        let base = url.absoluteString
        var opened = sqlite3_open_v2(base + "?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        if !opened {
            sqlite3_close(db); db = nil
            opened = sqlite3_open_v2(base + "?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        }
        defer { sqlite3_close(db) }
        guard opened, let db else { throw ImportError.unreadable("the file wouldn't open") }
        sqlite3_busy_timeout(db, 500)

        let sql = "SELECT phrase, replacement, observedSource, isSnippet, isDeleted FROM Dictionary"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var entries: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let phrase = text(stmt, 0) else { continue }
            entries.append(Entry(phrase: phrase, replacement: text(stmt, 1), observed: text(stmt, 2),
                                 isSnippet: sqlite3_column_int(stmt, 3) != 0,
                                 isDeleted: sqlite3_column_int(stmt, 4) != 0))
        }
        return entries
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, column) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Mapping

    /// What to add. A plain word becomes an expected word. A word with a replacement becomes a
    /// correction, and its replacement an expected word. A word Wispr learned from an edit also
    /// becomes a correction from what was first heard, unless that was an ordinary word (the same
    /// guard as Yapper's own edit learning: "for → Fore" must not rewrite every "for").
    static func plan(_ entries: [Entry], isDictionaryWord: (String) -> Bool) -> Plan {
        var plan = Plan()
        var seenTerms: Set<String> = []
        func addTerm(_ term: String) {
            if seenTerms.insert(term.lowercased()).inserted { plan.terms.append(term) }
        }
        for entry in entries where !entry.isDeleted {
            if entry.isSnippet { plan.skippedSnippets += 1; continue }
            if let replacement = entry.replacement, replacement != entry.phrase {
                plan.rules.append(Replacement(heard: entry.phrase, typed: replacement))
                addTerm(replacement)
                continue
            }
            addTerm(entry.phrase)
            if let observed = entry.observed, observed != entry.phrase,
               observed.split(separator: " ").count <= 3 {
                let caseOnly = observed.lowercased() == entry.phrase.lowercased()
                if caseOnly || !isDictionaryWord(observed) {
                    plan.rules.append(Replacement(heard: observed, typed: entry.phrase))
                }
            }
        }
        return plan
    }
}
