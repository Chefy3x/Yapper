import Foundation
import llama

/// One small language model loaded through llama.cpp, run greedily on a private thread.
///
/// The C objects (model, context, sampler) are not thread-safe, so every call goes through one
/// serial queue; the async API only hops onto it. Generation is blocking compute, which is why
/// it isn't done on Swift's cooperative pool.
final class LlamaRunner: @unchecked Sendable {
    enum RunnerError: LocalizedError {
        case loadFailed, contextFailed, tokenizeFailed, decodeFailed(Int32), promptTooLong
        var errorDescription: String? {
            switch self {
            case .loadFailed: "The formatting model wouldn't load"
            case .contextFailed: "Couldn't set up the formatting model"
            case .tokenizeFailed: "Couldn't read the text for formatting"
            case .decodeFailed(let code): "The formatting model failed (\(code))"
            case .promptTooLong: "Too much text to format"
            }
        }
    }

    struct Output: Sendable {
        var text: String
        var promptTokens: Int
        var generatedTokens: Int
        var hitDeadline: Bool
        var promptSeconds: Double = 0
    }

    let modelURL: URL
    let contextLength: UInt32
    private let queue = DispatchQueue(label: "app.yapper.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    /// Model state after each fixed prompt prefix (instructions + examples), so a request only
    /// pays for its own few dozen tokens. Keyed by the prefix text; cleared on unload.
    private var prefixStates: [String: [UInt8]] = [:]

    private static let backend: Void = {
        // llama.cpp logs every tensor at load; Yapper's own log says what matters.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    init(modelURL: URL, contextLength: UInt32 = 4096) {
        self.modelURL = modelURL
        self.contextLength = contextLength
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    var isLoaded: Bool { queue.sync { context != nil } }

    func load() async throws {
        try await run { try self.loadOnQueue() }
    }

    /// Evaluates and caches `prefix` ahead of time, so the next request that starts with it is
    /// fast from the first token.
    func prime(prefix: String) async throws {
        try await run {
            try self.loadOnQueue()
            guard let context = self.context, let vocab = self.vocab, self.prefixStates[prefix] == nil else { return }
            llama_memory_clear(llama_get_memory(context), true)
            _ = try self.restoreOrEvaluate(prefix: prefix, context: context, vocab: vocab)
        }
    }

    func unload() async {
        await run {
            if let context = self.context { llama_free(context) }
            if let model = self.model { llama_model_free(model) }
            self.context = nil; self.model = nil; self.vocab = nil
            self.prefixStates.removeAll()
        }
    }

    /// Continues `prefix + suffix` until an end-of-turn token, `maxTokens`, or `deadline`. Both
    /// are chat-formatted text with special tokens spelled out; `prefix` is the part that repeats
    /// between requests and is evaluated once.
    func generate(prefix: String = "", suffix: String, maxTokens: Int, deadline: Date) async throws -> Output {
        try await run { try self.generateOnQueue(prefix: prefix, suffix: suffix, maxTokens: maxTokens, deadline: deadline) }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func run(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { cont in
            queue.async { work(); cont.resume() }
        }
    }

    // MARK: On the queue

    private func loadOnQueue() throws {
        guard context == nil else { return }
        _ = Self.backend
        var mparams = llama_model_default_params()
        #if arch(arm64)
        mparams.n_gpu_layers = 999   // the whole model on Metal
        #else
        mparams.n_gpu_layers = 0
        #endif
        guard let model = llama_model_load_from_file(modelURL.path, mparams) else { throw RunnerError.loadFailed }
        var cparams = llama_context_default_params()
        cparams.n_ctx = contextLength
        cparams.n_batch = 1024
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw RunnerError.contextFailed
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
    }

    private func generateOnQueue(prefix: String, suffix: String, maxTokens: Int, deadline: Date) throws -> Output {
        try loadOnQueue()
        guard let context, let vocab else { throw RunnerError.contextFailed }
        llama_memory_clear(llama_get_memory(context), true)

        let promptStart = Date()
        var prefixCount = 0
        if !prefix.isEmpty {
            prefixCount = try restoreOrEvaluate(prefix: prefix, context: context, vocab: vocab)
        }
        let tokens = try tokenize(suffix, vocab: vocab)
        guard prefixCount + tokens.count + maxTokens < Int(contextLength) else { throw RunnerError.promptTooLong }
        try decode(tokens, context: context)
        let start = prefixCount + tokens.count

        let promptSeconds = Date().timeIntervalSince(promptStart)
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else { throw RunnerError.contextFailed }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var bytes: [UInt8] = []
        var generated = 0
        var hitDeadline = false
        var piece = [CChar](repeating: 0, count: 256)
        while generated < maxTokens {
            if Date() >= deadline { hitDeadline = true; break }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { bytes += piece[0..<Int(n)].map { UInt8(bitPattern: $0) } }
            generated += 1
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw RunnerError.decodeFailed(status) }
        }
        return Output(text: String(decoding: bytes, as: UTF8.self), promptTokens: start,
                      generatedTokens: generated, hitDeadline: hitDeadline, promptSeconds: promptSeconds)
    }

    /// The prompt goes in batch-sized chunks; only the last chunk's logits are needed.
    private func decode(_ tokens: [llama_token], context: OpaquePointer) throws {
        let chunk = 1024
        var start = 0
        while start < tokens.count {
            let end = min(start + chunk, tokens.count)
            let status = tokens[start..<end].withUnsafeBufferPointer { buf -> Int32 in
                let batch = llama_batch_get_one(UnsafeMutablePointer(mutating: buf.baseAddress!), Int32(end - start))
                return llama_decode(context, batch)
            }
            guard status == 0 else { throw RunnerError.decodeFailed(status) }
            start = end
        }
    }

    /// Puts the model in the state it has after reading `prefix`, from the cache when it can.
    /// Returns the prefix's token count.
    private func restoreOrEvaluate(prefix: String, context: OpaquePointer, vocab: OpaquePointer) throws -> Int {
        let tokens = try tokenize(prefix, vocab: vocab)
        if let state = prefixStates[prefix] {
            let restored = state.withUnsafeBufferPointer { llama_state_seq_set_data(context, $0.baseAddress, $0.count, 0) }
            if restored > 0 { return tokens.count }
            llama_memory_clear(llama_get_memory(context), true)   // fall through and evaluate it
        }
        try decode(tokens, context: context)
        let size = llama_state_seq_get_size(context, 0)
        var state = [UInt8](repeating: 0, count: size)
        let written = state.withUnsafeMutableBufferPointer { llama_state_seq_get_data(context, $0.baseAddress, size, 0) }
        if written > 0 { prefixStates[prefix] = Array(state.prefix(written)) }
        return tokens.count
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, true)
        }
        guard n > 0 else { throw RunnerError.tokenizeFailed }
        return Array(tokens.prefix(Int(n)))
    }
}
