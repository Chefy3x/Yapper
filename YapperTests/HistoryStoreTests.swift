import Testing
import Foundation

// Retention is the product promise ("your drive doesn't fill up, your reads don't leak
// past the window"), so pruning, orphan sweeping, and audio resolution get exact coverage.
// All stores point at temp dirs — the real Application Support data is never touched.
@MainActor
struct HistoryStoreTests {

    private func makeDirs() -> (audio: URL, storage: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("YapperTests-\(UUID().uuidString)")
        let audio = base.appendingPathComponent("audio", isDirectory: true)
        let storage = base.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        return (audio, storage)
    }

    private func item(_ text: String, ageHours: Double = 0) -> ReadingItem {
        ReadingItem(id: UUID(),
                    sourceApp: "TestApp",
                    createdAt: Date().addingTimeInterval(-ageHours * 3600),
                    cleanedText: text,
                    rawText: text)
    }

    @discardableResult
    private func writeAudio(_ name: String, in dir: URL, ageHours: Double = 0) -> URL {
        let url = dir.appendingPathComponent(name)
        try? Data("mp3-bytes".utf8).write(to: url)
        if ageHours > 0 {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageHours * 3600)],
                ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Recording

    @Test func recordsNewestFirst() {
        let (audio, storage) = makeDirs()
        let store = HistoryStore(audioDir: audio, storageDir: storage)
        store.record(item: item("first"), voiceID: "v", audioFileName: nil, origin: .latest)
        store.record(item: item("second"), voiceID: "v", audioFileName: nil, origin: .selection)
        #expect(store.entries.map(\.cleanedText) == ["second", "first"])
    }

    @Test func persistsAcrossInstances() {
        let (audio, storage) = makeDirs()
        HistoryStore(audioDir: audio, storageDir: storage)
            .record(item: item("survives reload"), voiceID: "v", audioFileName: nil, origin: .conversation)
        let reloaded = HistoryStore(audioDir: audio, storageDir: storage)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.cleanedText == "survives reload")
        #expect(reloaded.entries.first?.origin == .conversation)
    }

    // MARK: - Pruning

    @Test func pruneDropsExpiredEntriesAndTheirAudio() {
        let (audio, storage) = makeDirs()
        let store = HistoryStore(audioDir: audio, storageDir: storage)
        let oldAudio = writeAudio("old.mp3", in: audio, ageHours: 2)
        let freshAudio = writeAudio("fresh.mp3", in: audio)

        store.record(item: item("old read", ageHours: 2), voiceID: "v", audioFileName: "old.mp3", origin: .latest)
        store.record(item: item("fresh read"), voiceID: "v", audioFileName: "fresh.mp3", origin: .latest)

        store.prune(retentionHours: 1)

        #expect(store.entries.map(\.cleanedText) == ["fresh read"])
        #expect(!FileManager.default.fileExists(atPath: oldAudio.path))
        #expect(FileManager.default.fileExists(atPath: freshAudio.path))
    }

    @Test func pruneSweepsOrphanedAudioAndPartFiles() {
        let (audio, storage) = makeDirs()
        let store = HistoryStore(audioDir: audio, storageDir: storage)
        let oldOrphan = writeAudio("orphan.mp3", in: audio, ageHours: 2)
        let oldPart = writeAudio("stale.mp3.part", in: audio, ageHours: 2)
        let youngOrphan = writeAudio("young.mp3", in: audio)

        store.prune(retentionHours: 1)

        #expect(!FileManager.default.fileExists(atPath: oldOrphan.path))
        #expect(!FileManager.default.fileExists(atPath: oldPart.path))
        // Young files survive even when unreferenced — they may belong to an in-flight read.
        #expect(FileManager.default.fileExists(atPath: youngOrphan.path))
    }

    // MARK: - Audio resolution

    @Test func audioURLRequiresAnExistingNonEmptyFile() {
        let (audio, storage) = makeDirs()
        let store = HistoryStore(audioDir: audio, storageDir: storage)
        let empty = audio.appendingPathComponent("empty.mp3")
        FileManager.default.createFile(atPath: empty.path, contents: nil)
        writeAudio("real.mp3", in: audio)

        func entry(_ file: String?) -> HistoryEntry {
            HistoryEntry(id: UUID(), sourceApp: "T", createdAt: Date(), cleanedText: "t",
                         rawText: "t", voiceID: "v", audioFileName: file, origin: .latest)
        }
        #expect(store.audioURL(for: entry(nil)) == nil)
        #expect(store.audioURL(for: entry("missing.mp3")) == nil)
        #expect(store.audioURL(for: entry("empty.mp3")) == nil)   // truncated/failed synth
        #expect(store.audioURL(for: entry("real.mp3")) != nil)
    }

    @Test func clearAllRemovesEntriesAndAudio() {
        let (audio, storage) = makeDirs()
        let store = HistoryStore(audioDir: audio, storageDir: storage)
        let file = writeAudio("clip.mp3", in: audio)
        store.record(item: item("read"), voiceID: "v", audioFileName: "clip.mp3", origin: .latest)

        store.clearAll()

        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Previews

    @Test func previewFlattensNewlinesAndTruncates() {
        let long = Array(repeating: "word", count: 40).joined(separator: "\n")   // 199 chars
        let entry = HistoryEntry(id: UUID(), sourceApp: "T", createdAt: Date(),
                                 cleanedText: long, rawText: long, voiceID: "v",
                                 audioFileName: nil, origin: .latest)
        #expect(!entry.preview.contains("\n"))
        #expect(entry.preview.hasSuffix("…"))
        #expect(entry.preview.count == 91)   // 90 + ellipsis

        let reading = item(long)
        #expect(reading.preview.count == 61)   // 60 + ellipsis
    }
}
