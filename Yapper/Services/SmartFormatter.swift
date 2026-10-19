import Foundation
import CryptoKit

/// The formatting model: Qwen3.5 2B (Apache-2.0), 4-bit, as a GGUF for llama.cpp. Downloaded on
/// request into Application Support, checked against Hugging Face's SHA-256, never bundled.
enum FormatterModel {
    static let displayName = "Qwen3.5 2B"
    static let fileName = "Qwen3.5-2B-Q4_K_M.gguf"
    static let url = URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!
    static let sha256 = "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223"
    static let byteCount: Int64 = 1_280_835_840
    static let approxSize = "1.3 GB"

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Yapper/Formatter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { folder.appendingPathComponent(fileName) }

    static var isDownloaded: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? nil
        return size == byteCount
    }

    /// Metal makes a 2B model fast enough to sit in the paste path; on Intel it isn't.
    static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

enum FormatterStatus: Equatable, Sendable {
    case unsupported
    case notDownloaded
    case downloading(progress: Double)
    case verifying
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying: true
        default: false
        }
    }
}

/// What happened to one transcript, for the log and the tests.
enum FormatOutcome: Equatable, Sendable {
    case skipped          // no cue, or formatting off
    case formatted        // the model's version went out
    case unchanged        // the model returned the text as it was
    case rejected(String) // the guard refused the model's version
    case timedOut
    case failed(String)
}

/// Runs a transcript through the model and the guard. Separate from `SmartFormatter` so the
/// real-model probe can drive it without the app around it.
enum FormatEngine {
    /// Whole formatting step, prompt included. Past it the raw transcript goes out: a dictation
    /// that lands late feels broken in a way an unformatted one doesn't.
    static let budget: TimeInterval = 3.0
    /// Filler alone gets far less. It shows up in nearly every dictation, the rules have already
    /// taken the stutters and um/uh out, and most of the time the model hands the text back
    /// unchanged; it isn't worth more than a blink of lag.
    static let fillerBudget: TimeInterval = 0.6
    /// Past this many words, filler alone doesn't send a dictation to the model at all: retyping
    /// a long one can't finish inside the filler budget.
    static let fillerMaxWords = 40
    /// Whether filler alone sends a dictation to the model. Off: on the user's own dictations it
    /// mostly handed the text back unchanged or ran out of time, adding up to 0.6 s for nothing,
    /// while the rules already take out um/uh, stutters and repeats. Comes back when the model
    /// only has to name the words to cut, which is fast at any length.
    static let fillerViaModel = false

    /// A "no wait, I mean" correction is applied by the model only in dictations up to this long.
    /// Past it the reply can't be written in time, and on the user's history the two slowest
    /// turns (2.6 s and 3.5 s) were exactly that: long dictations that timed out and changed nothing.
    static let correctionMaxWords = 60

    /// What sends a dictation to the model, and so how long it may take. Lists aren't on it:
    /// the rules lay them out reliably, and the model only ever saw the ones they couldn't
    /// ("a few things…" with no first or second), which it then failed to finish in time.
    static func plan(_ text: String, cleanup: Bool) -> TimeInterval? {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words >= 4 else { return nil }
        if FormatCues.hasCorrection(text) { return words <= correctionMaxWords ? budget : nil }
        guard fillerViaModel, cleanup, FormatCues.hasFiller(text),
              text.split(whereSeparator: \.isWhitespace).count <= fillerMaxWords else { return nil }
        return fillerBudget
    }

    static func format(_ text: String, mode: FormatMode, cleanup: Bool = false, runner: LlamaRunner,
                       budget override: TimeInterval? = nil) async -> (text: String, outcome: FormatOutcome) {
        guard let planned = plan(text, cleanup: cleanup) else { return (text, .skipped) }
        let budget = override ?? planned
        // A rough token count for the reply: the dictation itself plus list markup.
        let maxTokens = text.split(whereSeparator: \.isWhitespace).count * 2 + 48
        do {
            let result = try await runner.generate(prefix: FormatPrompt.prefix(mode: mode, cleanup: cleanup),
                                                   suffix: FormatPrompt.suffix(text: text), maxTokens: maxTokens,
                                                   deadline: Date().addingTimeInterval(budget))
            if result.hitDeadline { return (text, .timedOut) }
            switch FormatGuard.check(input: text, output: FormatPrompt.clean(result.text), mode: mode, cleanup: cleanup) {
            case .accept(let formatted): return (formatted, .formatted)
            case .unchanged: return (text, .unchanged)
            case .reject(let why): return (text, .rejected(why))
            }
        } catch {
            return (text, .failed(error.localizedDescription))
        }
    }
}

/// Voice In's formatting step: turns "first… second…" into a list and "3, no wait, 4" into "4",
/// on this Mac. Loads the model the moment you start talking, so it's ready by the time you
/// let go, and unloads it after a few idle minutes to give the 1.5 GB back.
@MainActor
final class SmartFormatter: ObservableObject {
    @Published private(set) var status: FormatterStatus

    static let idleUnload: TimeInterval = 300

    private var runner: LlamaRunner?
    private var idleTask: Task<Void, Never>?
    private var downloader: ModelDownloader?

    init() {
        status = !FormatterModel.isSupported ? .unsupported
            : FormatterModel.isDownloaded ? .ready : .notDownloaded
    }

    // MARK: Running

    /// The user started talking. Load now, and read the instructions for the app they're in, so
    /// the formatting step only has their words left to do by the time they let go.
    func warmUp(bundleID: String?, cleanup: Bool) {
        guard status == .ready else { return }
        let runner = self.runner ?? LlamaRunner(modelURL: FormatterModel.fileURL)
        self.runner = runner
        scheduleUnload()
        let prefix = FormatPrompt.prefix(mode: FormatMode.forApp(bundleID: bundleID), cleanup: cleanup)
        Task {
            do { try await runner.prime(prefix: prefix) } catch {
                Log.voice.error("Formatter load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The transcript, formatted when it asks for it and the result passes the guard; otherwise
    /// exactly what came in.
    func format(_ text: String, bundleID: String?, cleanup: Bool) async -> String {
        guard status == .ready, FormatEngine.plan(text, cleanup: cleanup) != nil else { return text }
        let runner = self.runner ?? LlamaRunner(modelURL: FormatterModel.fileURL)
        self.runner = runner
        let mode = FormatMode.forApp(bundleID: bundleID)
        let started = Date()
        let result = await FormatEngine.format(text, mode: mode, cleanup: cleanup, runner: runner)
        scheduleUnload()
        Log.voice.notice("Format (\(mode.rawValue, privacy: .public)): \(String(describing: result.outcome), privacy: .public) in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s")
        return result.text
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnload))
            guard let self, !Task.isCancelled, let runner = self.runner else { return }
            await runner.unload()
            Log.voice.info("Formatter unloaded after idle")
        }
    }

    // MARK: Download

    func download() {
        guard FormatterModel.isSupported, !status.isBusy else { return }
        status = .downloading(progress: 0)
        let downloader = ModelDownloader(
            onProgress: { [weak self] p in Task { @MainActor in self?.status = .downloading(progress: min(p, 0.99)) } },
            onFinish: { [weak self] result in Task { @MainActor in self?.finishDownload(result) } })
        self.downloader = downloader
        downloader.start(FormatterModel.url)
    }

    private func finishDownload(_ result: Result<URL, Error>) {
        downloader = nil
        switch result {
        case .failure(let error):
            status = .failed(error.localizedDescription)
        case .success(let temp):
            status = .verifying
            Task.detached(priority: .utility) { [weak self] in
                let ok = Self.verify(temp)
                if ok {
                    try? FileManager.default.removeItem(at: FormatterModel.fileURL)
                    try? FileManager.default.moveItem(at: temp, to: FormatterModel.fileURL)
                } else {
                    try? FileManager.default.removeItem(at: temp)
                }
                await MainActor.run { [weak self] in
                    self?.status = ok && FormatterModel.isDownloaded ? .ready : .failed("The download was damaged. Try again.")
                }
            }
        }
    }

    nonisolated private static func verify(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == FormatterModel.sha256
    }

    func deleteModel() async {
        if let runner { await runner.unload() }
        runner = nil
        try? FileManager.default.removeItem(at: FormatterModel.fileURL)
        status = FormatterModel.isSupported ? .notDownloaded : .unsupported
    }
}

/// A plain URLSession download with progress. The finished file is moved out of URLSession's
/// temporary location before the delegate returns, as URLSession requires.
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var finished = false

    init(onProgress: @escaping @Sendable (Double) -> Void, onFinish: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start(_ url: URL) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : FormatterModel.byteCount
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FormatterModel.folder.appendingPathComponent(FormatterModel.fileName + ".download")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        onFinish(result)
    }
}
