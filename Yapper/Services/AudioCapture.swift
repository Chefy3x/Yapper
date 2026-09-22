import AVFoundation
import CoreAudio

/// One selectable microphone. `uid` is CoreAudio's stable device UID (survives reboots and
/// re-plugs), which is what Settings persists.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum AudioInputDevices {
    /// Every device with at least one input stream, in CoreAudio order.
    static func list() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Resolve a persisted UID back to a live device ID. Nil when the device isn't connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        list().isEmpty ? nil : translate(uid)
    }

    private static func translate(_ uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// What the Voice In coordinator needs from a microphone. The real implementation wraps
/// AVAudioEngine; tests substitute a fake that feeds synthetic levels and samples.
@MainActor
protocol AudioCapturing: AnyObject {
    /// RMS level of each captured buffer, delivered on the main actor. Drives the hands-free VAD.
    var onLevel: ((Float) -> Void)? { get set }
    /// The input route changed underneath a running capture (AirPods connected, default input
    /// switched). The engine is already stopped; the coordinator should finish the turn.
    var onInterrupted: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start(deviceUID: String?) throws
    /// Stops recording and returns everything captured as 16 kHz mono float samples.
    func stop() -> [Float]
}

/// AVAudioEngine input tap → 16 kHz mono Float32, which is what Whisper wants. The tap runs on
/// CoreAudio's realtime thread; samples accumulate under a lock and levels are hopped to main.
@MainActor
final class AudioCapture: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    var onInterrupted: (() -> Void)?

    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    private var configObserver: NSObjectProtocol?
    nonisolated static let targetSampleRate: Double = 16_000

    enum CaptureError: LocalizedError {
        case noInputFormat, converterUnavailable, deviceNotFound
        var errorDescription: String? {
            switch self {
            case .noInputFormat: "No microphone input is available"
            case .converterUnavailable: "Couldn't set up audio conversion"
            case .deviceNotFound: "The selected microphone isn't connected"
            }
        }
    }

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        }
    }

    func start(deviceUID: String?) throws {
        guard !isRunning else { return }
        buffer.reset()

        let input = engine.inputNode
        if let uid = deviceUID {
            guard let deviceID = AudioInputDevices.deviceID(forUID: uid) else { throw CaptureError.deviceNotFound }
            try Self.select(deviceID: deviceID, on: input)
        }

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInputFormat }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw CaptureError.converterUnavailable }

        // The tap runs on CoreAudio's realtime messenger queue. A closure literal written here
        // would inherit this method's main-actor isolation and trip Swift 6's runtime executor
        // check on the first buffer (SIGTRAP in dispatch_assert_queue). So the body lives in a
        // plain Sendable object and the closure is explicitly @Sendable — no isolation, no check.
        let processor = TapProcessor(
            converter: converter,
            target: target,
            ratio: Self.targetSampleRate / inputFormat.sampleRate,
            sink: buffer,
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in self?.onLevel?(level) }
            }
        )
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable pcm, _ in
            processor.process(pcm)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        Log.voice.info("AudioCapture started @\(inputFormat.sampleRate, privacy: .public)Hz ch=\(inputFormat.channelCount, privacy: .public)")
    }

    func stop() -> [Float] {
        guard isRunning else { return buffer.drain() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        let samples = buffer.drain()
        Log.voice.info("AudioCapture stopped: \(samples.count, privacy: .public) samples (\(String(format: "%.1f", Double(samples.count) / Self.targetSampleRate), privacy: .public)s)")
        return samples
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        Log.voice.notice("Audio route changed mid-capture; ending the turn with what we have")
        // Don't drain here — the coordinator's stop() collects the samples.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        onInterrupted?()
    }

    private static func select(deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw CaptureError.deviceNotFound }
        var id = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.deviceNotFound }
    }

    nonisolated static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Converts each realtime input buffer to 16 kHz mono and hands it to the sample buffer.
/// Deliberately not actor-isolated: it is called on CoreAudio's queue, never on main.
private final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let ratio: Double
    private let sink: SampleBuffer
    private let onLevel: @Sendable (Float) -> Void

    init(converter: AVAudioConverter, target: AVAudioFormat, ratio: Double,
         sink: SampleBuffer, onLevel: @escaping @Sendable (Float) -> Void) {
        self.converter = converter
        self.target = target
        self.ratio = ratio
        self.sink = sink
        self.onLevel = onLevel
    }

    func process(_ pcm: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let feed = OneShotFeed(pcm)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if let next = feed.take() { status.pointee = .haveData; return next }
            status.pointee = .noDataNow
            return nil
        }
        guard error == nil, let channel = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        sink.append(samples)
        onLevel(AudioCapture.rms(samples))
    }
}

/// Hands one input buffer to AVAudioConverter exactly once. The converter's input block is
/// `@Sendable`, so the buffer has to travel inside something the compiler accepts.
private final class OneShotFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}

/// Lock-protected sample accumulator shared between the realtime tap and the main actor.
final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ new: [Float]) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: new)
    }

    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    func reset() { _ = drain() }
}
