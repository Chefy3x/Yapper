import Testing
import Foundation
import AVFoundation

/// Opt-in: runs the real Whisper model on a synthetic 90 s quiet dictation and prints every
/// segment, with and without the prompt and the audio conditioning. Set YAPPER_WHISPER_PROBE=1.
struct WhisperLongDictationProbe {
    static let enabled = ProcessInfo.processInfo.environment["YAPPER_WHISPER_PROBE"] != nil

    private static let sentences = [
        "Okay so I want to go over the plan for the next part of the app before we start building anything.",
        "The first thing is the recording, it should start the moment I press the key and not cut off my first word.",
        "Then when I let go it should type what I said into whatever window I was in, without me pressing anything else.",
        "If a video is playing it should pause while I talk and then pick up again when I am done.",
        "I also want it to learn the names I fix by hand so I do not have to keep correcting the same thing every day.",
        "And the last thing is the formatting, so when I list a few things it comes out as an actual list.",
    ]

    private func speech() throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [Float] = []
        let pause = [Float](repeating: 0, count: 16_000 * 2)
        var round = 0
        while Double(out.count) / 16_000 < 88 {
            for (i, sentence) in Self.sentences.enumerated() {
                let file = dir.appendingPathComponent("s\(round)-\(i).wav")
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-o", file.path, "--file-format=WAVE", "--data-format=LEI16@16000", sentence]
                try say.run(); say.waitUntilExit()
                let audio = try AVAudioFile(forReading: file)
                let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
                try audio.read(into: buffer)
                out += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                out += pause
            }
            round += 1
        }
        // Scale to a quiet mic (speech around 0.017 RMS, what the user's recording measured) and
        // add a little room noise.
        let levels = TranscriptFilter.frameLevels(out).filter { $0 > 0.01 }.sorted()
        let scale = 0.017 / levels[levels.count / 2]
        var gen = SystemRandomNumberGenerator()
        return out.map { $0 * scale + Float.random(in: -0.0015...0.0015, using: &gen) }
    }

    @Test(.enabled(if: enabled)) func longQuietDictation() async throws {
        let samples = try speech()
        let transcriber = WhisperTranscriber(model: .recommended) { _ in }
        let prompt = TranscriptCorrector.prompt(terms: [], screenWords: [
            "WhisperKit", "Yapper", "Claude", "Hopper", "Superwhisper", "REA", "MediaRemote", "Qwen",
            "XcodeGen", "Sparkle", "ElevenLabs", "Vercel", "Zephyra", "GPT5", "MCP", "kubectl", "SwiftUI", "Wispr",
        ])
        let conditioned = AudioConditioner.condition(samples).samples
        print("PROBE audio \(Double(samples.count) / 16_000)s, conditioned \(Double(conditioned.count) / 16_000)s, hasSpeech=\(TranscriptFilter.hasSpeech(samples))")
        let short = Array(samples.prefix(16_000 * 25))
        let variants: [(String, [Float], String?)] = [
            ("short/none", short, nil),
            ("short/one-word", short, "Yapper."),
            ("short/sentence", short, " I use Yapper, WhisperKit and Claude every day."),
            ("short/list", short, prompt),
            ("long/list", conditioned, prompt),
        ]
        for (name, audio, p) in variants {
            let segments = try await transcriber.rawSegments(samples: audio, prompt: p)
            let joined = TranscriptFilter.join(segments, audioHasSpeech: true, audioSeconds: Double(audio.count) / 16_000)
            print("PROBE \(name): \(segments.count) segments → \(joined.count) chars")
            for seg in segments {
                print(String(format: "PROBE   start=%.1f lp=%.2f ns=%.2f cr=%.2f ", seg.start ?? -1, seg.avgLogprob, seg.noSpeechProb, seg.compressionRatio)
                      + "\"\(seg.text.prefix(90))\"")
            }
        }
    }
}
