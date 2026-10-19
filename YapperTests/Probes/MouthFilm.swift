import Testing
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Opt-in: films the Loud Mouth acting out a recording, frame by frame, through the same reader,
/// timeline and director the app runs, then thinking and a grin as a turn ends. Motion is a matter
/// of taste, so this makes something to watch rather than something to assert.
/// YAPPER_MOUTH_FILM=<output folder> (TEST_RUNNER_… through xcodebuild) writes PNGs to
/// <folder>/frames and the jaw's opening per frame to <folder>/jaw.csv; YAPPER_MOUTH_FILM_AUDIO picks
/// the speech (default site/audio/river-1.mp3), YAPPER_MOUTH_FILM_FPS the frame rate (default 60)
/// and YAPPER_MOUTH_SHAPES=0 leaves out the viseme net. Join the frames with the audio using ffmpeg.
struct MouthFilm {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static let outDir = env["YAPPER_MOUTH_FILM"]

    @Test(.enabled(if: outDir != nil)) func film() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let audioURL = URL(fileURLWithPath: Self.env["YAPPER_MOUTH_FILM_AUDIO"] ?? repo.appendingPathComponent("site/audio/river-1.mp3").path)
        let fps = Double(Self.env["YAPPER_MOUTH_FILM_FPS"] ?? "") ?? 60
        let out = URL(fileURLWithPath: Self.outDir!).appendingPathComponent("frames")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let audio = try Self.mono16k(audioURL)
        let asset = try MouthRigTests.asset()
        let renderer = try MouthRenderer(asset: asset)
        let model = MouthModel(asset: asset, springs: 0.5)
        let reader = MouthReader(sampleRate: MouthLive.rate)
        // the viseme net picks the lips' shapes, as in the app; YAPPER_MOUTH_SHAPES=0 films the reader alone
        let visemes = Self.env["YAPPER_MOUTH_SHAPES"] == "0" ? nil : MouthVisemes(model: try MouthVisemesTests.model())
        var timeline = MouthTimeline()
        var director = MouthDirector()

        // The mic hands over 10 ms at a time and each is read 2 ms later, as in the app.
        let hop = Int(MouthLive.rate * 0.01)
        var fed = 0
        var jawTrace = "t,J\n"
        let talk = Double(audio.count) / MouthLive.rate + 0.3
        let total = talk + 0.9 + 0.7
        for f in 0..<Int(total * fps) {
            let now = Double(f) / fps
            while fed + hop <= audio.count, Double(fed + hop) / MouthLive.rate + 0.002 <= now {
                let chunk = Array(audio[fed..<(fed + hop)])
                let made = MouthDrive.zip(reader.feed(chunk), visemes?.feed(chunk))
                fed += hop
                timeline.add(made, at: Double(fed) / MouthLive.rate + 0.002, shapeLag: visemes?.lookahead ?? 0)
            }
            let mode: MouthMode = now < talk ? .live : now < talk + 0.9 ? .thinking : .reacting(.done)
            let frame = director.frame(mode: mode, at: now) { timeline.drive(at: $0) }
            var framing = MouthFraming(rotationDegrees: asset.view.rotationDegrees + frame.head)
            framing.squash = frame.squash
            model.pose(frame.pose, dt: frame.dt)
            jawTrace += "\(now),\(frame.pose.J)\n"
            let image = try #require(renderer.image(model, framing: framing, width: 480, height: 300))
            let url = out.appendingPathComponent(String(format: "%05d.png", f))
            let dst = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dst, image, nil)
            CGImageDestinationFinalize(dst)
        }
        try jawTrace.write(to: out.deletingLastPathComponent().appendingPathComponent("jaw.csv"), atomically: true, encoding: .utf8)
        print("mouth film: \(Int(total * fps)) frames at \(Int(fps)) fps → \(out.path)")
    }

    /// The file's first channel at the reader's 16 kHz.
    static func mono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MouthLive.rate, channels: 1, interleaved: false)!
        let src = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: src)
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
        let dst = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * MouthLive.rate / file.processingFormat.sampleRate) + 1024))
        var given = false
        converter.convert(to: dst, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true; status.pointee = .haveData; return src
        }
        return Array(UnsafeBufferPointer(start: dst.floatChannelData![0], count: Int(dst.frameLength)))
    }
}
