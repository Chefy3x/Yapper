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

/// The quick reader, until the full one lands: loudness opens the jaw (with a pop on each new
/// syllable), the balance of bright to low voice energy picks wide or round lips (ee is bright,
/// oo and oh are dark), and hiss brings the teeth together. Everything eases through the demo
/// clips' near-critical springs.
final class MouthLoudnessReader: MouthVoiceReading {
    static let hop = 160                                  // 10 ms at 16 kHz
    private var pending: [Float] = []
    private var low = Biquad.bandpass(520, q: 0.9), mid = Biquad.bandpass(2300, q: 1.0), hiss = Biquad.highpass(4500)
    private var floor: Float = -50
    private var peak: Float = -30
    private var energy: Float = 0
    private var lastLow: Float = -90
    private var brightMean: Float = 0, brightVar: Float = 16
    private var jaw = Spring(), width = Spring(), teeth = Spring()

    func reset() {
        pending = []; floor = -50; peak = -30; energy = 0; lastLow = -90; brightMean = 0; brightVar = 16
        low.reset(); mid.reset(); hiss.reset(); jaw = Spring(); width = Spring(); teeth = Spring()
    }

    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthDrive] {
        pending.append(contentsOf: samples)
        var out: [MouthDrive] = []
        var start = 0
        while pending.count - start >= Self.hop {
            var all: Float = 0, eLow: Float = 0, eMid: Float = 0, eHiss: Float = 0
            for i in start..<start + Self.hop {
                let x = pending[i]
                all += x * x
                let l = low.run(x), m = mid.run(x), h = hiss.run(x)
                eLow += l * l; eMid += m * m; eHiss += h * h
            }
            start += Self.hop
            func db(_ e: Float) -> Float { 10 * log10(max(1e-14, e / Float(Self.hop))) }
            energy += (all - energy) * 0.45                // ~20 ms: smooths over single pitch periods
            let level = db(energy), lowDB = db(eLow)
            floor = max(-62, min(floor, level))
            floor += 0.02                                 // drift back up, as the pill's bars do
            // the loudest you've been lately (falls 3 dB a second): loud syllables open fully
            peak = max(level, peak - 0.03, floor + 18)
            let speaking = level > floor + 8

            let span = max(6, peak - floor - 6)
            var goalJ = pow(min(1, max(0, (level - floor - 6) / span)), 1.4)
            let rise = lowDB - lastLow                    // a new syllable: open a touch further
            lastLow += (lowDB - lastLow) * 0.3
            if rise > 4 { goalJ = min(1.1, goalJ + min(0.2, (rise - 4) * 0.03)) }

            var goalW: Float = 0, goalT: Float = 0
            if speaking {
                let bright = db(eMid) - lowDB
                brightMean += (bright - brightMean) * 0.01
                brightVar += ((bright - brightMean) * (bright - brightMean) - brightVar) * 0.01
                goalW = min(0.9, max(-0.9, 0.6 * (bright - brightMean) / max(2, brightVar.squareRoot())))
                if eHiss / max(1e-12, all) > 0.25 { goalT = 0.85; goalJ = min(goalJ, 0.15) }
            } else {
                goalJ = 0
            }
            let J = jaw.step(to: goalJ, open: 9, close: 10.5, damping: 0.78)
            let W = width.step(to: goalW, open: 7, close: 7, damping: 0.9)
            let T = teeth.step(to: goalT, open: 10, close: 10, damping: 0.9)
            out.append(MouthDrive(J: max(0, J), W: W, T: max(0, T)))
        }
        pending.removeFirst(start)
        return out
    }

    /// A second-order follower stepped once per 10 ms hop.
    struct Spring {
        var x: Float = 0, v: Float = 0
        mutating func step(to goal: Float, open: Float, close: Float, damping z: Float) -> Float {
            let w0 = 2 * Float.pi * (goal > x ? open : close), h: Float = 0.01 / 4
            for _ in 0..<4 { v += (w0 * w0 * (goal - x) - 2 * z * w0 * v) * h; x += v * h }
            return x
        }
    }

    /// RBJ cookbook filters at 16 kHz.
    struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        static func bandpass(_ f: Float, q: Float) -> Biquad {
            let w = 2 * Float.pi * f / 16_000, a = sin(w) / (2 * q), a0 = 1 + a
            return Biquad(b0: a / a0, b1: 0, b2: -a / a0, a1: -2 * cos(w) / a0, a2: (1 - a) / a0)
        }
        static func highpass(_ f: Float) -> Biquad {
            let w = 2 * Float.pi * f / 16_000, a = sin(w) / (2 * 0.707), c = cos(w), a0 = 1 + a
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - a) / a0)
        }
        mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
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

    init(reader: MouthVoiceReading = MouthLoudnessReader()) {
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
