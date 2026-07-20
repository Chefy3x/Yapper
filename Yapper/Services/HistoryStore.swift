import Foundation
import Combine

/// One spoken item, persisted for replay within the rolling retention window.
struct HistoryEntry: Identifiable, Codable, Hashable {
    enum Origin: String, Codable {
        case latest, selection, conversation

        var symbol: String {
            switch self {
            case .latest:       "text.bubble.fill"
            case .selection:    "text.cursor"
            case .conversation: "bubble.left.and.bubble.right.fill"
            }
        }
        var label: String {
            switch self {
            case .latest:       "Read latest"
            case .selection:    "Selection"
            case .conversation: "Conversation"
            }
        }
    }

    let id: UUID
    let sourceApp: String
    let createdAt: Date
    let cleanedText: String
    let rawText: String
    let voiceID: String
    /// Filename (within the audio cache dir) of the synthesized MP3, if any. nil for native reads.
    let audioFileName: String?
    let origin: Origin

    var preview: String {
        let oneLine = cleanedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.count <= 90 { return oneLine }
        return String(oneLine.prefix(90)) + "…"
    }
}

/// Persists recently spoken items to disk and prunes them on a rolling retention window.
/// Audio is reused from the TTS cache for instant replay; when the cache file is gone the
/// caller re-synthesizes from `cleanedText`.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let audioDir: URL

    /// `storageDir` overrides where history.json lives — tests use a temp dir so they never
    /// touch the real Application Support store.
    init(audioDir: URL = TTSCoordinator.cacheDir(), storageDir: URL? = nil) {
        self.audioDir = audioDir
        let dir: URL
        if let storageDir {
            dir = storageDir
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = support.appendingPathComponent("Yapper", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    // MARK: - Recording

    func record(item: ReadingItem, voiceID: String, audioFileName: String?, origin: HistoryEntry.Origin) {
        let entry = HistoryEntry(
            id: item.id,
            sourceApp: item.sourceApp,
            createdAt: item.createdAt,
            cleanedText: item.cleanedText,
            rawText: item.rawText,
            voiceID: voiceID,
            audioFileName: audioFileName,
            origin: origin
        )
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        save()
    }

    // MARK: - Mutations

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        deleteAudio(for: entry)
        save()
    }

    func clearAll() {
        for entry in entries { deleteAudio(for: entry) }
        entries.removeAll()
        save()
    }

    /// Drop entries older than the retention window (deleting their audio), then sweep orphaned
    /// cache files older than the window (old previews, pre-history leftovers).
    func prune(retentionHours: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionHours) * 3600)
        let expired = entries.filter { $0.createdAt < cutoff }
        for entry in expired { deleteAudio(for: entry) }
        entries.removeAll { $0.createdAt < cutoff }
        save()
        sweepOrphans(cutoff: cutoff)
    }

    // MARK: - Audio resolution

    /// The on-disk audio file for an entry, if it still exists and is non-empty.
    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        let url = audioDir.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return nil }
        return url
    }

    // MARK: - Persistence

    private func deleteAudio(for entry: HistoryEntry) {
        guard let name = entry.audioFileName else { return }
        try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(name))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([HistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        if let data = try? Self.encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func sweepOrphans(cutoff: Date) {
        let fm = FileManager.default
        let referenced = Set(entries.compactMap { $0.audioFileName })
        guard let files = try? fm.contentsOfDirectory(
            at: audioDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        // .part files are in-progress synthesis temps; old ones are leftovers from a killed app.
        for file in files where ["mp3", "part"].contains(file.pathExtension) {
            if referenced.contains(file.lastPathComponent) { continue }
            let mdate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if mdate < cutoff { try? fm.removeItem(at: file) }
        }
    }

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
}
