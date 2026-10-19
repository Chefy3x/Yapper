import Foundation
import AVFoundation
import QuartzCore

/// One moment of the mouth as the voice reader hears it: jaw J (0 shut … 1 a big "ah"), width W
/// (negative is round) and teeth together T.
struct MouthDrive: Sendable, Equatable {
    var J: Float = 0, W: Float = 0, T: Float = 0
    static let rest = MouthDrive()

    func mixed(with other: MouthDrive, _ k: Float) -> MouthDrive {
        MouthDrive(J: J + (other.J - J) * k, W: W + (other.W - W) * k, T: T + (other.T - T) * k)
    }
}

/// Turns 16 kHz mono mic audio into one mouth drive per 10 ms hop. Only ever hears the past.
protocol MouthVoiceReading: AnyObject {
    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthDrive]
    func reset()
}

/// The live reader (`MouthReader`), remembering what it learns about your voice and mic between
/// turns so the mouth starts tuned.
final class MouthReaderVoice: MouthVoiceReading {
    static let statsKey = "mouthSpeakerStats"
    private let reader: MouthReader

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.statsKey).flatMap { try? JSONDecoder().decode(SpeakerStats.self, from: $0) }
        reader = MouthReader(sampleRate: MouthLive.rate, stats: saved)
    }

    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthDrive] {
        reader.feed(samples).map { MouthDrive(J: $0.J, W: $0.W, T: $0.T) }
    }

    /// A new turn: keep what was learned (saved for next launch too), clear the moment-to-moment state.
    func reset() {
        if let data = try? JSONEncoder().encode(reader.stats) { UserDefaults.standard.set(data, forKey: Self.statsKey) }
        reader.reset()
    }
}

/// Low-latency mic audio for the mouth. The engine's sink node hands every ~10 ms input buffer to
/// `push` on the audio thread, which only copies it into a preallocated ring. A serial queue
/// drains the ring every 10 ms, brings it to 16 kHz mono and runs the reader; the mouth view asks
/// for `drive(at:)` once per frame.
final class MouthLive: @unchecked Sendable {
    static let rate: Double = 16_000
    /// How far behind the newest reading the mouth plays, so a late buffer never makes it stall.
    static let playout: CFTimeInterval = 0.02

    private let reader: MouthVoiceReading
    private let queue = DispatchQueue(label: "app.yapper.mouth", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // the audio thread's ring (input rate, mono)
    private let ringLock = NSLock()
    private let capacity = 96_000
    private let ring: UnsafeMutablePointer<Float>
    private var ringWrite = 0, ringCount = 0

    // drained on the queue
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MouthLive.rate, channels: 1, interleaved: false)!

    // read on main
    private let drivesLock = NSLock()
    private var drives: [(t: CFTimeInterval, d: MouthDrive)] = []

    init(reader: MouthVoiceReading = MouthReaderVoice()) {
        self.reader = reader
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
    }

    deinit { timer?.cancel(); ring.deallocate() }

    /// Called when capture starts, with the mic's own rate.
    func start(inputRate: Double) {
        queue.async { [self] in
            inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)
            converter = inputFormat.flatMap { AVAudioConverter(from: $0, to: outputFormat) }
            reader.reset()
            ringLock.lock(); ringWrite = 0; ringCount = 0; ringLock.unlock()
            drivesLock.lock(); drives = []; drivesLock.unlock()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.drain() }
            timer?.cancel()
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            drivesLock.lock(); drives = []; drivesLock.unlock()
        }
    }

    /// The audio thread: copy channel 0 (`stride` apart for interleaved input) into the ring.
    func push(_ samples: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        ringLock.lock()
        for i in 0..<count {
            ring[ringWrite] = samples[i * stride]
            ringWrite = (ringWrite + 1) % capacity
        }
        ringCount = min(capacity, ringCount + count)
        ringLock.unlock()
    }

    private func drain() {
        guard let converter, let inputFormat else { return }
        ringLock.lock()
        let n = ringCount
        guard n > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(n)) else {
            ringLock.unlock(); return
        }
        let dst = input.floatChannelData![0]
        let begin = (ringWrite - n + capacity) % capacity
        for i in 0..<n { dst[i] = ring[(begin + i) % capacity] }
        ringCount = 0
        ringLock.unlock()
        input.frameLength = AVAudioFrameCount(n)
        let now = CACurrentMediaTime()

        let ratio = Self.rate / inputFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(n) * ratio) + 32) else { return }
        let once = Once(input)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if let next = once.take() { status.pointee = .haveData; return next }
            status.pointee = .noDataNow
            return nil
        }
        guard error == nil, out.frameLength > 0 else { return }
        let made = reader.feed(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        guard !made.isEmpty else { return }
        drivesLock.lock()
        for (k, d) in made.enumerated() {                 // the last hop ends about now
            drives.append((now - Double(made.count - 1 - k) * 0.01, d))
        }
        if drives.count > 200 { drives.removeFirst(drives.count - 200) }
        drivesLock.unlock()
    }

    /// Where the mouth should be at host time `now`: the readings, a little behind, blended.
    func drive(at now: CFTimeInterval) -> MouthDrive {
        let t = now - Self.playout
        drivesLock.lock(); defer { drivesLock.unlock() }
        guard let last = drives.last else { return .rest }
        if t >= last.t { return now - last.t > 0.3 ? .rest : last.d }
        guard let i = drives.lastIndex(where: { $0.t <= t }) else { return drives[0].d }
        let a = drives[i], b = drives[i + 1]
        return a.d.mixed(with: b.d, Float((t - a.t) / max(1e-6, b.t - a.t)))
    }
}

/// Hands one buffer to AVAudioConverter exactly once (its input block is `@Sendable`).
private final class Once: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}
