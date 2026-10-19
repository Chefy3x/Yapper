import Foundation
import Combine

/// One Voice In turn, kept so it can be found again: copied, pasted again, played back, or run
/// through the speech model again. Distinct from `HistoryEntry`, which is what Yapper read aloud.
struct Dictation: Identifiable, Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case pasted     // typed into the app
        case copied     // the paste didn't land; the words were left on the clipboard
        case empty      // nothing but silence or filler
        case failed     // the speech model threw
        case retried    // empty or failed at the time, transcribed again later; never pasted
    }

    var id: UUID = UUID()
    var at: Date
    var appName: String?
    var bundleID: String?
    /// What the speech model heard, before corrections, formatting and snippets.
    var heard: String
    /// What was typed.
    var text: String
    var duration: TimeInterval
    var outcome: Outcome
    var modelID: String?
    /// File name inside the store's audio folder, when the recording was kept.
    var audioFileName: String?
    var error: String?

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    /// Whether cleanup, corrections, formatting or a snippet changed the words themselves.
    /// Case and punctuation alone don't count; the speech model's own punctuation varies.
    var wasCleaned: Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        }
        return !heard.isEmpty && words(heard) != words(text)
    }
}

/// How long dictations are kept. Recordings never outlive `DictationHistoryStore.audioCeiling`.
enum DictationRetention: String, CaseIterable, Identifiable, Sendable {
    case never, day, week, month, forever
    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .never:   0
        case .day:     86_400
        case .week:    7 * 86_400
        case .month:   30 * 86_400
        case .forever: nil
        }
    }

    var label: String {
        switch self {
        case .never:   "Don't keep"
        case .day:     "1 day"
        case .week:    "1 week"
        case .month:   "1 month"
        case .forever: "Forever"
        }
    }
}

/// Every dictation, newest first, as JSON in Application Support/Yapper, with recordings as
/// 16-bit WAVs beside it. Never leaves the machine. Written after the paste, so it costs the
/// turn nothing.
@MainActor
final class DictationHistoryStore: ObservableObject {
    @Published private(set) var entries: [Dictation] = []

    /// A recording is 32 KB a second; a month of them is gigabytes. They go after a week even
    /// when the text stays longer.
    static let audioCeiling: TimeInterval = 7 * 86_400
    /// Past this many entries the oldest go, whatever the retention says.
    static let maxEntries = 5_000

    let audioDir: URL
    private let fileURL: URL

    /// `directory` overrides where the store lives; tests use a temp dir.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dictations.json")
        audioDir = dir.appendingPathComponent("Dictations", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([Dictation].self, from: data) {
            entries = decoded
        }
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Yapper", isDirectory: true)
    }

    // MARK: Recording

    /// Adds a dictation. With `samples`, its recording is written beside it; `record` returns
    /// once the entry is in the list, and the audio lands a moment later.
    @discardableResult
    func record(_ dictation: Dictation, samples: [Float]? = nil) -> Dictation {
        var entry = dictation
        if let samples, !samples.isEmpty {
            entry.audioFileName = "\(entry.id.uuidString).wav"
            let store = LastRecording(url: audioDir.appendingPathComponent(entry.audioFileName!))
            pendingAudio[entry.id] = Task { await store.save(samples) }
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            for old in entries[Self.maxEntries...] { deleteAudio(old) }
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
        return entry
    }

    /// Recordings still being written, so a replay right after the turn waits for the file.
    private var pendingAudio: [UUID: Task<Void, Never>] = [:]

    /// A transcribe-again result replaces the text, keeping when and where it was said.
    func update(_ id: UUID, heard: String, text: String, outcome: Dictation.Outcome, modelID: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].heard = heard
        entries[i].text = text
        entries[i].outcome = outcome
        entries[i].modelID = modelID
        entries[i].error = nil
        save()
    }

    func remove(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        deleteAudio(entries[i])
        entries.remove(at: i)
        save()
    }

    func clearAll() {
        for entry in entries { deleteAudio(entry) }
        entries.removeAll()
        save()
        sweepOrphanAudio()
    }

    /// Drops what's older than the retention window, and recordings older than the audio
    /// ceiling (or than the window, if that's shorter).
    func prune(retention: DictationRetention, now: Date = Date()) {
        var changed = false
        if let window = retention.interval {
            let cutoff = now.addingTimeInterval(-window)
            let (keep, drop) = (entries.filter { $0.at >= cutoff }, entries.filter { $0.at < cutoff })
            if !drop.isEmpty {
                drop.forEach(deleteAudio)
                entries = keep
                changed = true
            }
        }
        let audioWindow = min(retention.interval ?? .infinity, Self.audioCeiling)
        let audioCutoff = now.addingTimeInterval(-audioWindow)
        for i in entries.indices where entries[i].audioFileName != nil && entries[i].at < audioCutoff {
            deleteAudio(entries[i])
            entries[i].audioFileName = nil
            changed = true
        }
        if changed { save() }
    }

    // MARK: Audio

    func audioURL(for entry: Dictation) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        let url = audioDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) || pendingAudio[entry.id] != nil ? url : nil
    }

    func loadAudio(for entry: Dictation) async -> [Float]? {
        await pendingAudio[entry.id]?.value
        pendingAudio[entry.id] = nil
        guard let url = audioURL(for: entry) else { return nil }
        return await LastRecording(url: url).load()
    }

    /// Waits for every recording still being written. Tests and quit.
    func flushAudio() async {
        for (id, task) in pendingAudio {
            await task.value
            pendingAudio[id] = nil
        }
    }

    private func deleteAudio(_ entry: Dictation) {
        guard let name = entry.audioFileName else { return }
        let url = audioDir.appendingPathComponent(name)
        if let pending = pendingAudio.removeValue(forKey: entry.id) {
            Task { await pending.value; try? FileManager.default.removeItem(at: url) }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Recordings no entry points at: a crash between writing the audio and the list.
    func sweepOrphanAudio() {
        let known = Set(entries.compactMap(\.audioFileName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? []
        for file in files where file.hasSuffix(".wav") && !known.contains(file) {
            let id = UUID(uuidString: String(file.dropLast(4)))
            if let id, pendingAudio[id] != nil { continue }
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(file))
        }
    }

    // MARK: Searching

    /// Case- and diacritic-insensitive match on the typed text, what was heard, and the app.
    func search(_ query: String) -> [Dictation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter {
            $0.text.range(of: q, options: opts) != nil
                || $0.heard.range(of: q, options: opts) != nil
                || ($0.appName?.range(of: q, options: opts) != nil)
        }
    }

    /// Words dictated across everything kept, for the page header.
    var totalWords: Int { entries.reduce(0) { $0 + ($1.outcome == .pasted || $1.outcome == .copied ? $1.wordCount : 0) } }

    // MARK: Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save() {
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
