import Testing

struct SpeechModelCatalogTests {
    @Test func defaultsPerArchitecture() {
        #if arch(arm64)
        #expect(WhisperModel.recommended.engine == .parakeet)
        #expect(WhisperModel.catalog.first?.engine == .parakeet)
        #else
        #expect(WhisperModel.recommended.engine == .whisper)
        #expect(!WhisperModel.catalog.contains { $0.engine == .parakeet })
        #endif
    }

    @Test func whisperModelsStayAvailable() {
        let former = WhisperModel.named(WhisperModel.formerDefaultID)
        #expect(former.id == WhisperModel.formerDefaultID)
        #expect(former.engine == .whisper)
        #expect(WhisperModel.whisperCatalog.count == 4)
    }

    @Test func unknownIDsFallBackToTheRecommendedModel() {
        #expect(WhisperModel.named("no-such-model") == WhisperModel.recommended)
    }
}
