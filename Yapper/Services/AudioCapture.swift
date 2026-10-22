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

    /// True when the mic Voice In would open — the persisted one, else the system default input —
    /// is Bluetooth. Opening a Bluetooth mic flips the headset into its call profile, which drops
    /// playback quality for every app, so it must only happen when the user has asked to talk.
    static func isBluetooth(uid: String?) -> Bool {
        guard let id = uid.flatMap(translate) ?? defaultInputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The rate the device runs at, which is the rate the mic queue asks for (no conversion in it).
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
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

/// What the Voice In coordinator needs from a microphone. The real implementation is an
/// input-only AudioQueue; tests substitute a fake that feeds synthetic levels and samples.
@MainActor
protocol AudioCapturing: AnyObject {
    /// RMS level of each captured buffer, delivered on the main actor. Drives the hands-free VAD.
    var onLevel: ((Float) -> Void)? { get set }
    /// The input route changed underneath a running capture (AirPods connected, default input
    /// switched). The mic is already stopped; the coordinator should finish the turn.
    var onInterrupted: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start(deviceUID: String?) throws
    /// Stops recording and returns everything captured as 16 kHz mono float samples.
    func stop() -> [Float]
    /// Whether opening this input has side effects beyond the mic indicator (a Bluetooth headset
    /// switching profiles). Such inputs are never opened speculatively.
    func isDisruptive(deviceUID: String?) -> Bool
}

extension AudioCapturing {
    func isDisruptive(deviceUID: String?) -> Bool { false }
}

/// An input-only AudioQueue → 16 kHz mono Float32, which is what Whisper wants.
///
/// Not AVAudioEngine: on the Mac its input and output share one I/O unit, so opening the mic
/// started the speakers on the mic's I/O loop too (CADefaultDeviceAggregate). That loop's first
/// cycles page-faulted and overran on about a third of presses (2026-10-22 logs), and every
/// overrun crackled the speakers right over the start chime. An input queue never touches an
/// output device, and its buffers come back on a dispatch queue, off CoreAudio's realtime thread.
@MainActor
final class AudioCapture: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    var onInterrupted: (() -> Void)?

    private(set) var isRunning = false

    private let buffer = SampleBuffer()
    /// The Loud Mouth's low-latency feed, when the pill shows the mouth. Whisper's path takes
    /// ~85 ms at a time; the mouth gets every 10 ms buffer as it arrives.
    var mouthFeed: MouthLive?
    /// The feed this turn started, which is the one to stop even if Settings swapped it since.
    private var activeMouth: MouthLive?
    private var mic: MicQueue?
    private var routeWatches: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    nonisolated static let targetSampleRate: Double = 16_000

    enum CaptureError: LocalizedError {
        case noInputFormat, converterUnavailable, deviceNotFound, queueFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .noInputFormat: "No microphone input is available"
            case .converterUnavailable: "Couldn't set up audio conversion"
            case .deviceNotFound: "The selected microphone isn't connected"
            case .queueFailed(let status): "Couldn't open the microphone (\(status))"
            }
        }
    }

    func start(deviceUID: String?) throws {
        guard !isRunning else { return }
        buffer.reset()
        let requestedAt = DispatchTime.now()

        let deviceID: AudioDeviceID
        if let uid = deviceUID {
            guard let id = AudioInputDevices.deviceID(forUID: uid) else { throw CaptureError.deviceNotFound }
            deviceID = id
        } else {
            guard let id = AudioInputDevices.defaultInputDevice() else { throw CaptureError.noInputFormat }
            deviceID = id
        }
        let rate = AudioInputDevices.nominalSampleRate(deviceID)
        guard rate > 0 else { throw CaptureError.noInputFormat }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                              channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw CaptureError.converterUnavailable }

        let processor = TapProcessor(
            converter: converter,
            target: target,
            ratio: Self.targetSampleRate / rate,
            sink: buffer,
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in self?.onLevel?(level) }
            }
        )
        let mouth = mouthFeed
        let mic = try MicQueue(format: inputFormat, deviceUID: deviceUID, processor: processor, mouth: mouth,
                               onFirstAudio: {
            // How long the user waits between "open the mic" and audio actually arriving —
            // the gap that eats first words. .notice so it persists and can be compared.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - requestedAt.uptimeNanoseconds) / 1_000_000
            Log.voice.notice("Mic first audio after \(String(format: "%.0f", ms), privacy: .public)ms")
        })
        mouth?.start(inputRate: rate)
        do {
            try mic.start()
        } catch {
            mic.stop()
            mouth?.stop()
            throw error
        }
        self.mic = mic
        activeMouth = mouth
        watchRoute(deviceID: deviceID, followsDefault: deviceUID == nil)
        isRunning = true
        let startMs = Double(DispatchTime.now().uptimeNanoseconds - requestedAt.uptimeNanoseconds) / 1_000_000
        Log.voice.notice("AudioCapture started @\(rate, privacy: .public)Hz (input-only) in \(String(format: "%.0f", startMs), privacy: .public)ms")
    }

    func stop() -> [Float] {
        guard isRunning else { return buffer.drain() }
        close()
        let samples = buffer.drain()
        Log.voice.info("AudioCapture stopped: \(samples.count, privacy: .public) samples (\(String(format: "%.1f", Double(samples.count) / Self.targetSampleRate), privacy: .public)s)")
        return samples
    }

    func isDisruptive(deviceUID: String?) -> Bool {
        AudioInputDevices.isBluetooth(uid: deviceUID)
    }

    private func close() {
        unwatchRoute()
        mic?.stop()
        mic = nil
        activeMouth?.stop()
        activeMouth = nil
        isRunning = false
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        Log.voice.notice("Audio route changed mid-capture; ending the turn with what we have")
        // Don't drain here — the coordinator's stop() collects the samples.
        close()
        onInterrupted?()
    }

    /// The mic in use going away, or (when following the system's) the default input changing,
    /// ends the turn. Output changes don't: this capture never touches an output.
    private func watchRoute(deviceID: AudioDeviceID, followsDefault: Bool) {
        var watches = [(AudioObjectID(deviceID), kAudioDevicePropertyDeviceIsAlive)]
        if followsDefault {
            watches.append((AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice))
        }
        for (object, selector) in watches {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.handleConfigurationChange() }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                routeWatches.append((object, address, block))
            }
        }
    }

    private func unwatchRoute() {
        for (object, address, block) in routeWatches {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        routeWatches = []
    }

    nonisolated static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// The input queue itself: mono Float32 at the mic's own rate, in 10 ms buffers. Deliberately not
/// actor-isolated: its callback block is written here, so it runs on `callbackQueue` without
/// inheriting the main actor (which would trip Swift 6's runtime executor check, SIGTRAP).
private final class MicQueue: @unchecked Sendable {
    private static let bufferSeconds = 0.01
    private static let bufferCount = 8
    /// Whisper's chunk, as the old 4096-frame tap gave it: the levels and the VAD were tuned on it.
    private static let chunkFrames: AVAudioFrameCount = 4096

    private let callbackQueue = DispatchQueue(label: "app.yapper.mic", qos: .userInteractive)
    private let processor: TapProcessor
    private let mouth: MouthLive?
    private let onFirstAudio: @Sendable () -> Void
    /// Filled and emptied only on `callbackQueue`.
    private let chunk: AVAudioPCMBuffer
    private var sawFirst = false
    private let runningLock = NSLock()
    private var running = false
    private var queue: AudioQueueRef?

    init(format: AVAudioFormat, deviceUID: String?, processor: TapProcessor, mouth: MouthLive?,
         onFirstAudio: @escaping @Sendable () -> Void) throws {
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames)
        else { throw AudioCapture.CaptureError.converterUnavailable }
        self.chunk = chunk
        self.processor = processor
        self.mouth = mouth
        self.onFirstAudio = onFirstAudio

        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var made: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&made, &description, 0, callbackQueue) {
            @Sendable [weak self] queue, buffer, _, _, _ in
            self?.received(buffer, on: queue)
        }
        guard status == noErr, let made else { throw AudioCapture.CaptureError.queueFailed(status) }
        queue = made

        if let uid = deviceUID {
            var cfUID = uid as CFString
            let set = withUnsafePointer(to: &cfUID) {
                AudioQueueSetProperty(made, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size))
            }
            guard set == noErr else { stop(); throw AudioCapture.CaptureError.deviceNotFound }
        }
        let bytes = UInt32((format.sampleRate * Self.bufferSeconds).rounded()) * 4
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            let allocated = AudioQueueAllocateBuffer(made, bytes, &buffer)
            guard allocated == noErr, let buffer else { stop(); throw AudioCapture.CaptureError.queueFailed(allocated) }
            AudioQueueEnqueueBuffer(made, buffer, 0, nil)
        }
    }

    func start() throws {
        guard let queue else { return }
        setRunning(true)
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else { setRunning(false); throw AudioCapture.CaptureError.queueFailed(status) }
    }

    /// Stops and frees the queue, then hands Whisper the part-filled last chunk. Once `running`
    /// is false a callback never touches its buffer, so one that arrives after the queue is
    /// freed is harmless; the first sync waits out one that was already reading.
    func stop() {
        guard let queue else { return }
        setRunning(false)
        callbackQueue.sync {}
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        self.queue = nil
        callbackQueue.sync { flush() }
    }

    private func setRunning(_ value: Bool) {
        runningLock.lock(); running = value; runningLock.unlock()
    }

    private func received(_ buffer: AudioQueueBufferRef, on queue: AudioQueueRef) {
        runningLock.lock(); let live = running; runningLock.unlock()
        guard live else { return }
        let frames = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        if frames > 0 {
            if !sawFirst { sawFirst = true; onFirstAudio() }
            let samples = UnsafePointer(buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self))
            mouth?.push(samples, count: frames)
            append(samples, count: frames)
        }
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func append(_ samples: UnsafePointer<Float>, count: Int) {
        let destination = chunk.floatChannelData![0]
        let capacity = Int(chunk.frameCapacity)
        var done = 0
        while done < count {
            let at = Int(chunk.frameLength)
            let n = min(count - done, capacity - at)
            (destination + at).update(from: samples + done, count: n)
            chunk.frameLength = AVAudioFrameCount(at + n)
            done += n
            if at + n == capacity { flush() }
        }
    }

    private func flush() {
        guard chunk.frameLength > 0 else { return }
        processor.process(chunk)
        chunk.frameLength = 0
    }
}

/// Converts each chunk of mic audio to 16 kHz mono and hands it to the sample buffer.
/// Deliberately not actor-isolated: it is called on the mic's queue, never on main.
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
