import AVFoundation

/// The most recent Voice In recording, kept on disk so a transcript that failed or came back
/// empty can be run again instead of being said twice. One file, replaced by every new
/// recording, never uploaded. Wispr Flow keeps its recordings for the same reason.
struct LastRecording: Sendable {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Yapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-recording.wav")
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 16-bit WAV at the capture rate: half the size of float, and nothing Whisper can hear is lost.
    func save(_ samples: [Float], sampleRate: Double = AudioCapture.targetSampleRate) async {
        let url = self.url
        await Task.detached(priority: .utility) {
            do {
                try Self.write(samples, sampleRate: sampleRate, to: url)
            } catch {
                Log.voice.error("Couldn't keep the recording: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }

    func load() async -> [Float]? {
        let url = self.url
        return await Task.detached(priority: .userInitiated) { try? Self.read(url) }.value
    }

    private static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        // Written beside the old one and swapped in, so a crash mid-write never leaves half a file.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".last-recording-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }   // the file closes here, before the swap
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    private static func read(_ url: URL) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
