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

/// The reader's drives laid out on the host clock, one every 10 ms of audio. Each is stamped by
/// where it falls in the audio, not by when its buffer happened to be drained, so the spacing stays
/// even however the mic delivers; the mouth plays a little behind the newest so a late buffer
/// doesn't make it stall and then jump.
struct MouthTimeline: Sendable {
    static let hop: Double = 0.01
    /// How far behind the audio the mouth plays: covers a Bluetooth headset's ~30 ms buffers as
    /// well as the drain's 10 ms.
    static let playout: CFTimeInterval = 0.045

    private(set) var drives: [(t: CFTimeInterval, d: MouthDrive)] = []
    /// Seconds of audio the reader has turned into drives.
    private var heard: Double = 0
    /// Host time minus audio time: the earliest any reading has arrived, creeping up slowly so it
    /// follows the two clocks drifting apart.
    private var offset: Double?
    private var lastAdd: CFTimeInterval = 0

    mutating func reset() { drives = []; heard = 0; offset = nil }

    /// Readings just made, the last of them ending about `now`.
    mutating func add(_ made: [MouthDrive], at now: CFTimeInterval) {
        guard !made.isEmpty else { return }
        heard += Double(made.count) * Self.hop
        let seen = now - heard
        if let o = offset { offset = min(o + 0.002 * max(0, now - lastAdd), seen) } else { offset = seen }
        lastAdd = now
        let end = heard + offset!
        for (k, d) in made.enumerated() {
            var t = end - Double(made.count - 1 - k) * Self.hop
            if let last = drives.last { t = max(t, last.t + 0.5 * Self.hop) }   // an earlier arrival never runs time back
            drives.append((t, d))
        }
        if drives.count > 200 { drives.removeFirst(drives.count - 200) }
    }

    /// Where the mouth should be at host time `now`: the readings, a little behind, blended.
    func drive(at now: CFTimeInterval) -> MouthDrive {
        let t = now - Self.playout
        guard let last = drives.last else { return .rest }
        if t >= last.t { return now - last.t > 0.3 ? .rest : last.d }
        guard let i = drives.lastIndex(where: { $0.t <= t }) else { return drives[0].d }
        let a = drives[i], b = drives[i + 1]
        return a.d.mixed(with: b.d, Float((t - a.t) / max(1e-6, b.t - a.t)))
    }
}

/// Eases the reader's drive before the mouth acts it out: follows it through a critically damped
/// spring, so every change leaves and lands softly. (The jaw itself goes pose to pose, through
/// `MouthMoveFollower`; the reader opens it for a syllable in about 50 ms, a pop in three frames.)
struct MouthDriveSmoother: Sendable {
    var hz: Float = 6
    private var x: SIMD3<Float>?
    private var v = SIMD3<Float>.zero

    mutating func reset() { x = nil; v = .zero }

    mutating func step(_ d: MouthDrive, dt: Float) -> MouthDrive {
        let goal = SIMD3(d.J, d.W, d.T)
        guard var p = x, dt > 0 else { x = goal; v = .zero; return d }
        let w = 2 * Float.pi * hz
        let n = max(1, Int((dt * 480).rounded(.up))), h = dt / Float(n)
        for _ in 0..<n { v += (w * w * (goal - p) - 2 * w * v) * h; p += v * h }
        x = p
        return MouthDrive(J: p.x, W: p.y, T: p.z)
    }
}

/// Pose to pose, the way an animator times a mouth: the jaw holds still through the small wiggles in
/// the voice, and when it really changes, makes one decisive move to the new pose that leaves at the
/// speed it already had and lands without a bump. A change mid-move just redirects it.
struct MouthMoveFollower: Sendable {
    /// A change this big starts (or redirects) a move.
    var threshold: Float = 0.10
    /// A smaller difference that lasts this long also gets a move, so slow drifts are followed.
    var drift: Float = 0.03, driftAfter: Float = 0.12
    /// Moves take this long, plus more for bigger ones, up to `longest`.
    var shortest: Float = 0.05, perUnit: Float = 0.08, longest: Float = 0.11

    private var p: Float?, v: Float = 0
    private var move: (p0: Float, v0: Float, to: Float, d: Float, u: Float)?
    private var off: Float = 0

    mutating func reset() { p = nil; v = 0; move = nil; off = 0 }

    mutating func step(_ goal: Float, dt: Float) -> Float {
        guard var x = p, dt > 0 else { p = goal; v = 0; move = nil; return goal }
        let target = move?.to ?? x
        off = abs(goal - target) > drift ? off + dt : 0
        if abs(goal - target) > threshold || off > driftAfter {
            let d = min(longest, shortest + perUnit * abs(goal - x))
            move = (x, v, goal, d, 0); off = 0
        }
        if var m = move {
            m.u = min(1, m.u + dt / m.d)
            // quintic from (p0, v0, no acceleration) to (to, still, no acceleration) over d
            let u = m.u, d = m.d, dp = m.to - m.p0, w = m.v0 * d
            let h1 = 10 * u * u * u - 15 * u * u * u * u + 6 * u * u * u * u * u
            let h2 = u - 6 * u * u * u + 8 * u * u * u * u - 3 * u * u * u * u * u
            let dh1 = (30 * u * u - 60 * u * u * u + 30 * u * u * u * u) / d
            let dh2 = (1 - 18 * u * u + 32 * u * u * u - 15 * u * u * u * u) / d
            x = m.p0 + dp * h1 + w * h2
            v = dp * dh1 + w * dh2
            move = m.u >= 1 ? nil : m
            if m.u >= 1 { x = m.to; v = 0 }
        }
        p = x
        return x
    }
}

/// Low-latency mic audio for the mouth. The engine's sink node hands every ~10 ms input buffer to
/// `push` on the audio thread, which only copies it into a preallocated ring. A serial queue
/// drains the ring every 10 ms, brings it to 16 kHz mono and runs the reader; the mouth view asks
/// for `drive(at:)` once per frame.
final class MouthLive: @unchecked Sendable {
    static let rate: Double = 16_000

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

    // read on the render thread
    private let drivesLock = NSLock()
    private var timeline = MouthTimeline()

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
            drivesLock.lock(); timeline.reset(); drivesLock.unlock()
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
            drivesLock.lock(); timeline.reset(); drivesLock.unlock()
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
        timeline.add(made, at: now)
        drivesLock.unlock()
    }

    /// Where the mouth should be at host time `now`.
    func drive(at now: CFTimeInterval) -> MouthDrive {
        drivesLock.lock(); defer { drivesLock.unlock() }
        return timeline.drive(at: now)
    }
}

/// Hands one buffer to AVAudioConverter exactly once (its input block is `@Sendable`).
private final class Once: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}
