import Testing
import Foundation

/// Opt-in: the context check replayed on saved dictations, as the app now runs it (hinted spots
/// plus spots found by sound against your terms). No screen names: those aren't saved.
/// YAPPER_CC_REPLAY=<Yapper's Application Support folder>. Prints each spot with a few words
/// around it, its score and whether it would swap.
struct ContextCheckReplay {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPPER_CC_REPLAY"] != nil))
    func replay() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAPPER_CC_REPLAY"]!)
        let vocab = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("vocabulary.json"))) as? [String: Any] ?? [:]
        let terms = vocab["terms"] as? [String] ?? []
        let heardAs = vocab["heardAs"] as? [String: [String]] ?? [:]
        let rows = (try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("dictations.json"))) as? [[String: Any]]) ?? []
        let texts = rows.compactMap { $0["heard"] as? String }.filter { !$0.isEmpty }
        let names = SoundAlikes.names(terms) { WordKnowledge.isDictionaryWord($0) }
        print("REPLAY \(texts.count) dictations, names by sound: \(names.joined(separator: ", "))")

        let runner = LlamaRunner(modelURL: FormatterModel.fileURL)
        try await runner.load()
        var total = 0, hinted = 0, taken = 0, time = 0.0
        for text in texts {
            var spots = SoundAlikes.spots(in: text, heardAs: heardAs, terms: terms)
            for s in SoundAlikes.phoneticSpots(in: text, names: names) where !spots.contains(where: { $0.utf8.overlaps(s.utf8) }) {
                spots.append(s)
            }
            for spot in spots.prefix(ContextCheck.maxQuestions) {
                let t = Date()
                guard let advantage = await ContextCheck.advantage(runner, in: text, at: spot, terms: terms) else { continue }
                time += Date().timeIntervalSince(t)
                total += 1
                if spot.hinted { hinted += 1 }
                let swap = advantage > (spot.hinted ? ContextCheck.margin : ContextCheck.unhintedMargin)
                if swap { taken += 1 }
                let around = SoundAlikes.versions(of: text, around: spot, words: 6).heard
                print(String(format: "REPLAY %@ %@ %+.1f  %@ → %@  | %@", swap ? "SWAP" : "keep", spot.hinted ? "hint " : "sound",
                             advantage, spot.heard, spot.term, around))
            }
        }
        print(String(format: "REPLAY %d spots (%d hinted), %d swapped, %.2fs average", total, hinted, taken, time / Double(max(1, total))))
    }
}
