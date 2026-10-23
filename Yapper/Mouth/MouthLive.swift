import Foundation
import AVFoundation
import QuartzCore

/// One moment of the mouth as the voice reader hears it: jaw J (0 shut … 1 a big "ah"), width W
/// (negative is round) and teeth together T, plus the shape the viseme net hears (all zero when it
/// isn't running or hasn't caught up), and whether the reader counts it as speech (1) or a pause (0).
struct MouthDrive: Sendable, Equatable {
    var J: Float = 0, W: Float = 0, T: Float = 0
    var shape = MouthShapes()
    var speaking: Float = 0
    static let rest = MouthDrive()

    func mixed(with other: MouthDrive, _ k: Float) -> MouthDrive {
        MouthDrive(J: J + (other.J - J) * k, W: W + (other.W - W) * k, T: T + (other.T - T) * k,
                   shape: shape + (other.shape - shape) * k, speaking: speaking + (other.speaking - speaking) * k)
    }

    /// Whether the viseme net said anything about this moment.
    var hasShape: Bool { shape.sum() > 0.5 }

    /// The reader's frames with the viseme net's answers from the same samples. The net answers for
    /// the hop `lookahead` hops back, so `shape` here belongs to an earlier drive: MouthTimeline puts
    /// it back where it belongs (`add(_:at:shapeLag:)`).
    static func zip(_ frames: [MouthFrame], _ shapes: [MouthShapes?]?) -> [MouthDrive] {
        frames.enumerated().map { k, f in
            MouthDrive(J: f.J, W: f.W, T: f.T, shape: (shapes?.indices.contains(k) ?? false ? shapes![k] : nil) ?? MouthShapes(),
                       speaking: f.speaking ? 1 : 0)
        }
    }
}

/// Turns 16 kHz mono mic audio into one mouth drive per 10 ms hop. Only ever hears the past.
protocol MouthVoiceReading: AnyObject {
    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthDrive]
    func reset()
    /// How many hops behind the drives their `shape` runs.
    var shapeLag: Int { get }
}

extension MouthVoiceReading {
    var shapeLag: Int { 0 }
}

/// The live reader (`MouthReader`), remembering what it learns about your voice and mic between
/// turns so the mouth starts tuned, and the viseme net for the lips' shapes (without it, the reader
/// alone drives the mouth).
final class MouthReaderVoice: MouthVoiceReading {
    static let statsKey = "mouthSpeakerStats"
    /// The viseme net is off unless this is set: on a real iPhone-mic voice it read background hiss as
    /// an "s" and parted the lips over the teeth in every pause, so it waits for a model that passes.
    static let shapesKey = "mouthShapes"
    private let reader: MouthReader
    private let visemes: MouthEar?

    init(shapes: Bool = UserDefaults.standard.bool(forKey: MouthReaderVoice.shapesKey)) {
        let saved = UserDefaults.standard.data(forKey: Self.statsKey).flatMap { try? JSONDecoder().decode(SpeakerStats.self, from: $0) }
        reader = MouthReader(sampleRate: MouthLive.rate, stats: saved)
        // the WavLM ear when it's installed, else the bundled small net
        visemes = shapes ? MouthWavLM.installed() ?? (try? MouthVisemeModel.bundled()).map(MouthVisemes.init(model:)) : nil
    }

    var shapeLag: Int { visemes?.lookahead ?? 0 }

    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthDrive] {
        MouthDrive.zip(reader.feed(samples), visemes?.feed(samples))
    }

    /// A new turn: keep what was learned (saved for next launch too), clear the moment-to-moment state.
    func reset() {
        if let data = try? JSONEncoder().encode(reader.stats) { UserDefaults.standard.set(data, forKey: Self.statsKey) }
        reader.reset()
        visemes?.reset()
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
    /// This timeline's playout: longer for an ear that hears further ahead, so its shapes are in
    /// before the mouth needs them (the jaw waits with them, keeping the two together).
    var playout: CFTimeInterval = MouthTimeline.playout

    static func playout(shapeLag: Int) -> CFTimeInterval { max(playout, Double(shapeLag) * hop + 0.005) }

    private(set) var drives: [(t: CFTimeInterval, d: MouthDrive)] = []
    /// The viseme net's shapes, stamped with their drive's time. They arrive a few hops after it.
    private(set) var shapes: [(t: CFTimeInterval, s: MouthShapes)] = []
    /// Seconds of audio the reader has turned into drives.
    private var heard: Double = 0
    /// Host time minus audio time: the earliest any reading has arrived, creeping up slowly so it
    /// follows the two clocks drifting apart.
    private var offset: Double?
    private var lastAdd: CFTimeInterval = 0

    mutating func reset() { drives = []; shapes = []; heard = 0; offset = nil }

    /// Readings just made, the last of them ending about `now`. Their shapes belong `shapeLag` hops
    /// further back.
    mutating func add(_ made: [MouthDrive], at now: CFTimeInterval, shapeLag: Int = 0) {
        guard !made.isEmpty else { return }
        heard += Double(made.count) * Self.hop
        let seen = now - heard
        if let o = offset { offset = min(o + 0.002 * max(0, now - lastAdd), seen) } else { offset = seen }
        lastAdd = now
        let end = heard + offset!
        for (k, d) in made.enumerated() {
            var t = end - Double(made.count - 1 - k) * Self.hop
            if let last = drives.last { t = max(t, last.t + 0.5 * Self.hop) }   // an earlier arrival never runs time back
            var plain = d
            plain.shape = MouthShapes()
            drives.append((t, plain))
        }
        for (k, d) in made.enumerated() where d.hasShape {
            let i = drives.count - made.count + k - shapeLag
            if i >= 0 { shapes.append((drives[i].t, d.shape)) }
        }
        if drives.count > 200 { drives.removeFirst(drives.count - 200) }
        if shapes.count > 200 { shapes.removeFirst(shapes.count - 200) }
    }

    /// Where the mouth should be at host time `now`: the readings, a little behind, blended.
    func drive(at now: CFTimeInterval) -> MouthDrive {
        let t = now - playout
        guard let last = drives.last else { return .rest }
        var d: MouthDrive
        if t >= last.t {
            if now - last.t > 0.3 { return .rest }
            d = last.d
        } else if let i = drives.lastIndex(where: { $0.t <= t }) {
            let a = drives[i], b = drives[i + 1]
            d = a.d.mixed(with: b.d, Float((t - a.t) / max(1e-6, b.t - a.t)))
        } else {
            d = drives[0].d
        }
        d.shape = shape(at: t)
        return d
    }

    /// The shape at audio-stamped time `t`, blended; past the newest one, the newest held (the net
    /// runs 40 ms behind and a late buffer can leave it a hop short of the playout).
    private func shape(at t: CFTimeInterval) -> MouthShapes {
        guard let last = shapes.last else { return MouthShapes() }
        if t >= last.t { return last.s }
        guard let i = shapes.lastIndex(where: { $0.t <= t }) else { return shapes[0].s }
        let a = shapes[i], b = shapes[i + 1]
        return a.s + (b.s - a.s) * Float((t - a.t) / max(1e-6, b.t - a.t))
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

/// Pose to pose, eased: the jaw lets the smallest wiggles in the voice pass, and when it changes,
/// glides to the new pose, leaving at the speed it already had and landing without a bump. A change
/// mid-move just redirects it. Moves start on small changes and take long enough to glide; the
/// snappier timing (bigger threshold, 50-110 ms moves) read as choppy, stop-motion.
struct MouthMoveFollower: Sendable {
    /// A change this big starts (or redirects) a move.
    var threshold: Float = 0.04
    /// A smaller difference that lasts this long also gets a move, so slow drifts are followed.
    var drift: Float = 0.015, driftAfter: Float = 0.05
    /// Moves take this long, plus more for bigger ones, up to `longest`.
    var shortest: Float = 0.09, perUnit: Float = 0.10, longest: Float = 0.18

    private var p: Float?, v: Float = 0
    private var move: (p0: Float, v0: Float, to: Float, d: Float, u: Float)?
    private var off: Float = 0

    init(threshold: Float = 0.04, shortest: Float = 0.09, perUnit: Float = 0.10, longest: Float = 0.18) {
        self.threshold = threshold; self.shortest = shortest; self.perUnit = perUnit; self.longest = longest
    }

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

/// Low-latency mic audio for the mouth. The mic queue hands every 10 ms input buffer to `push`
/// on its own thread, which only copies it into a preallocated ring. A serial queue
/// drains the ring every 10 ms, brings it to 16 kHz mono and runs the reader; the mouth view asks
/// for `drive(at:)` once per frame.
final class MouthLive: @unchecked Sendable {
    static let rate: Double = 16_000

    private var reader: MouthVoiceReading
    /// Builds a new reader when the ear picked in Settings changes.
    private let makeReader: (() -> MouthVoiceReading)?
    private var readerEar: String
    private let queue = DispatchQueue(label: "app.yapper.mouth", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // the mic thread's ring (input rate, mono)
    private let ringLock = NSLock()
    private let capacity = 96_000
    private let ring: UnsafeMutablePointer<Float>
    private var ringWrite = 0, ringCount = 0

    // drained on the queue
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    /// Made once per turn: allocating while holding `ringLock` stalls the audio thread waiting on
    /// it, and under memory pressure that stall is long enough to crackle the mic.
    private var drainBuffer: AVAudioPCMBuffer?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MouthLive.rate, channels: 1, interleaved: false)!

    // read on the render thread
    private let drivesLock = NSLock()
    private var timeline = MouthTimeline()

    /// The app's: a `MouthReaderVoice`, rebuilt at the next turn when another ear is picked.
    convenience init() {
        self.init(reader: MouthReaderVoice(), rebuild: { MouthReaderVoice() })
    }

    init(reader: MouthVoiceReading, rebuild: (() -> MouthVoiceReading)? = nil) {
        self.reader = reader
        makeReader = rebuild
        readerEar = MouthWavLM.chosenHead
        timeline.playout = MouthTimeline.playout(shapeLag: reader.shapeLag)
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
    }

    deinit { timer?.cancel(); ring.deallocate() }

    /// Called when capture starts, with the mic's own rate.
    func start(inputRate: Double) {
        // Touch every page of the ring now, before the mic writes into it: after a quiet spell
        // the system may have compressed them, and the first pushes would fault them back in.
        ringLock.lock()
        ring.update(repeating: 0, count: capacity)
        ringWrite = 0; ringCount = 0
        ringLock.unlock()
        queue.async { [self] in
            inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)
            converter = inputFormat.flatMap { AVAudioConverter(from: $0, to: outputFormat) }
            drainBuffer = inputFormat.flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(capacity)) }
            reader.reset()
            if let makeReader, MouthWavLM.chosenHead != readerEar {
                reader = makeReader()
                readerEar = MouthWavLM.chosenHead
            }
            drivesLock.lock(); timeline.reset(); timeline.playout = MouthTimeline.playout(shapeLag: reader.shapeLag); drivesLock.unlock()
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

    /// The mic's thread: copy channel 0 (`stride` apart for interleaved input) into the ring.
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
        guard let converter, let inputFormat, let input = drainBuffer else { return }
        let dst = input.floatChannelData![0]
        ringLock.lock()
        let n = ringCount
        guard n > 0 else { ringLock.unlock(); return }
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
        timeline.add(made, at: now, shapeLag: reader.shapeLag)
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
