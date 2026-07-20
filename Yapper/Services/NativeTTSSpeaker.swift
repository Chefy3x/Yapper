import AVFoundation

/// Fallback speaker built on the macOS-native AVSpeechSynthesizer. Used when ElevenLabs is
/// unconfigured, unreachable, or returns an error.
@MainActor
final class NativeTTSSpeaker {

    enum State { case idle, speaking, paused, finished }

    @Published private(set) var state: State = .idle

    /// Called when the utterance finishes or is cancelled. Lets the coordinator advance a queue.
    var onFinish: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private let delegate = Delegate()

    init() {
        synth.delegate = delegate
        delegate.onFinish = { [weak self] in
            self?.state = .finished
            self?.onFinish?()
        }
    }

    func speak(_ text: String, voiceID: String? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        synth.speak(utterance)
        state = .speaking
    }

    func pause() {
        synth.pauseSpeaking(at: .word)
        state = .paused
    }

    func resume() {
        synth.continueSpeaking()
        state = .speaking
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        state = .idle
    }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        var onFinish: (() -> Void)?
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            onFinish?()
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            onFinish?()
        }
    }
}
