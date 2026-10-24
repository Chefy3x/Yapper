import Foundation

/// What the user's voice sounds like, learned from their own dictations, so `BackgroundSpeechGate`
/// can tell their quiet words from someone else's.
///
/// The average of WeSpeaker embeddings of the loud words in each dictation (the user, near the
/// mic). Replayed over the user's 1,400 dictations, a print from the first few dozen still
/// mistook the user's own quiet words for someone else's; from 150 on it never did. It then
/// keeps averaging over the most recent 500, long enough that a loud TV in one dictation can't
/// move it and short enough to follow a new mic. Every dictation counts: an earlier version
/// skipped ones that didn't match yet, and that locked the print onto a few early recordings.
/// Kept in Application Support, never uploaded.
struct VoicePrint: Codable, Equatable, Sendable {
    /// The embedding model it was learned with. A print from another model compares as noise.
    var model: String
    var mean: [Float] = []
    var count = 0

    /// Dictations learned before the print is used.
    static let readyAfter = 150
    /// The newest dictation weighs at least 1/this, so the print follows the user's voice.
    static let memory = 500
    /// Loud audio a dictation needs before it is learned from: under this a voice embedding is noise.
    static let minLearnSeconds: Double = 3

    var isReady: Bool { count >= Self.readyAfter }

    mutating func learn(_ embedding: [Float]) {
        let e = Self.normalized(embedding)
        guard !e.isEmpty else { return }
        if mean.count != e.count { mean = [Float](repeating: 0, count: e.count); count = 0 }
        count += 1
        let w = 1 / Float(min(count, Self.memory))
        for i in mean.indices { mean[i] += (e[i] - mean[i]) * w }
    }

    /// Cosine similarity to the learned voice, nil until it is ready.
    func similarity(_ embedding: [Float]) -> Float? {
        guard isReady, embedding.count == mean.count else { return nil }
        let a = Self.normalized(mean), b = Self.normalized(embedding)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard n > 1e-9, n.isFinite else { return [] }
        return v.map { $0 / n }
    }
}

/// The print on disk: one small JSON file next to the dictation history.
struct VoicePrintStore: Sendable {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Yapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiceprint.json")
    }

    func load(model: String) -> VoicePrint {
        guard let data = try? Data(contentsOf: url),
              let print = try? JSONDecoder().decode(VoicePrint.self, from: data),
              print.model == model else { return VoicePrint(model: model) }
        return print
    }

    func save(_ print: VoicePrint) {
        do {
            try JSONEncoder().encode(print).write(to: url, options: .atomic)
        } catch {
            Log.voice.error("Couldn't keep the voice print: \(error.localizedDescription, privacy: .public)")
        }
    }
}
