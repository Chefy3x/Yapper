import Testing
import Foundation
import SQLite3

/// Opt-in: scores Yapper's cleanup against Wispr Flow's on the user's own dictation history.
/// YAPPER_WISPR_EVAL=<path to a copy of flow.sqlite>, YAPPER_WISPR_EVAL_N=<sample size>.
/// Reads the copy only; prints totals and a few short examples, writes nothing.
struct WisprCleanupEval {
    static let path = ProcessInfo.processInfo.environment["YAPPER_WISPR_EVAL"]
    static let sample = Int(ProcessInfo.processInfo.environment["YAPPER_WISPR_EVAL_N"] ?? "") ?? 150
    /// YAPPER_FORMAT_MODEL=<gguf file name in the Formatter folder> to score another model.
    static let modelURL = ProcessInfo.processInfo.environment["YAPPER_FORMAT_MODEL"]
        .map { FormatterModel.folder.appendingPathComponent($0) } ?? FormatterModel.fileURL

    private func pairs() -> [(asr: String, wispr: String)] {
        guard let path = Self.path else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT asrText, formattedText FROM History WHERE asrText IS NOT NULL AND formattedText IS NOT NULL ORDER BY timestamp"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var all: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let a = String(cString: sqlite3_column_text(stmt, 0)), b = String(cString: sqlite3_column_text(stmt, 1))
            let n = a.split(separator: " ").count
            if (6...60).contains(n) { all.append((a, b)) }
        }
        guard all.count > Self.sample else { return all }
        let step = Double(all.count) / Double(Self.sample)
        return (0..<Self.sample).map { all[Int(Double($0) * step)] }
    }

    private func words(_ s: String) -> [String] { FormatGuard.words(FormatGuard.stripListMarkers(s)) }

    /// Indices of `a` that survive into `b`, by longest common subsequence.
    private func kept(_ a: [String], _ b: [String]) -> Set<Int> {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var t = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: Set<Int> = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.insert(i); i += 1; j += 1 }
            else if t[i + 1][j] >= t[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    @Test(.enabled(if: path != nil && FileManager.default.fileExists(atPath: modelURL.path)))
    func compareWithWisprFlow() async throws {
        let rows = pairs()
        print("EVAL model \(Self.modelURL.lastPathComponent)")
        let runner = LlamaRunner(modelURL: Self.modelURL)
        try await runner.load()
        var wisprDeleted = 0
        var stats: [String: (ours: Int, agree: Int)] = ["rules": (0, 0), "rules+model": (0, 0)]
        var outcomes: [String: Int] = [:]
        var times: [Double] = []
        var falseCuts: [String] = []
        for (asr, wispr) in rows {
            let a = words(asr)
            let wisprGone = Set(a.indices).subtracting(kept(a, words(wispr)))
            wisprDeleted += wisprGone.count
            let rules = Disfluency.clean(asr)
            let started = Date()
            let (final, outcome) = await FormatEngine.format(rules, mode: .chat, cleanup: true, runner: runner)
            if outcome != .skipped { times.append(Date().timeIntervalSince(started)) }
            let key: String
            switch outcome {
            case .rejected(let why): key = "rejected: " + (why.split(separator: "\"").first.map(String.init) ?? why)
            default: key = String(describing: outcome)
            }
            outcomes[key, default: 0] += 1
            for (name, text) in [("rules", rules), ("rules+model", final)] {
                let gone = Set(a.indices).subtracting(kept(a, words(text)))
                stats[name]!.ours += gone.count
                stats[name]!.agree += gone.intersection(wisprGone).count
                if name == "rules+model", falseCuts.count < 10 {
                    let wrong = gone.subtracting(wisprGone).sorted().map { a[$0] }
                    if !wrong.isEmpty, asr.count < 220 { falseCuts.append("cut [\(wrong.joined(separator: " "))] in: \(asr)") }
                }
            }
        }
        print("EVAL dictations=\(rows.count) words=\(rows.reduce(0) { $0 + words($1.asr).count }) wisprDeleted=\(wisprDeleted)")
        for name in ["rules", "rules+model"] {
            let s = stats[name]!
            print(String(format: "EVAL %@: removed %d, agrees with Wispr %d → precision %.0f%%, catches %.0f%% of Wispr's cuts",
                         name, s.ours, s.agree, 100 * Double(s.agree) / Double(max(1, s.ours)),
                         100 * Double(s.agree) / Double(max(1, wisprDeleted))))
        }
        for (k, v) in outcomes.sorted(by: { $0.value > $1.value }) { print("EVAL outcome \(k): \(v)") }
        let sorted = times.sorted()
        if !sorted.isEmpty {
            print(String(format: "EVAL model time p50 %.2fs p90 %.2fs max %.2fs (n=%d)", sorted[sorted.count / 2],
                         sorted[sorted.count * 9 / 10], sorted.last!, sorted.count))
        }
        for line in falseCuts { print("EVAL  \(line)") }
    }
}
