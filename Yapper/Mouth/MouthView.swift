import SwiftUI
import Metal
import QuartzCore

/// What the mouth is doing on screen.
enum MouthMode: Equatable {
    /// Lip-syncing the mic, live.
    case live
    /// The words are being worked out: chewing it over.
    case thinking
    /// The turn just ended: a grin when the words landed, a grimace when nothing did.
    case reacting(MouthReaction)
    /// Held still in one pose (Settings' preview).
    case still(MouthPose)
}

/// How the mouth sees a turn off, in the moment before the pill closes.
enum MouthReaction: Equatable, Sendable { case done, cancel }

/// The pieces every mouth on screen shares: the exported rig and one renderer, whose shaders
/// compile once. `warmUp` does that early so the pill's first opening doesn't hitch.
@MainActor
final class MouthStage {
    static let shared = MouthStage()
    private var ready: (asset: MouthAsset, renderer: MouthRenderer)?
    private var failed = false

    func prepare() -> (asset: MouthAsset, renderer: MouthRenderer)? {
        if let ready { return ready }
        guard !failed else { return nil }
        do {
            let asset = try MouthAsset.bundled()
            ready = (asset, try MouthRenderer(asset: asset))
        } catch {
            failed = true
            Log.app.error("Loud Mouth unavailable: \(error.localizedDescription, privacy: .public)")
        }
        return ready
    }

    func warmUp() { _ = prepare() }

    /// The size the mouth is drawn at; `MouthFraming`'s defaults fit it (about 85 pt wide at rest).
    static let viewSize = CGSize(width: 160, height: 100)

    /// The thinking loop at `t` seconds: chewing it over. The lips purse and drift side to side and
    /// the jaw works a little, pressing the lips together between bites.
    nonisolated static func thinking(_ t: Double) -> MouthPose {
        let side = Float(sin(2 * Double.pi * 0.42 * t))
        let purse = Float(sin(2 * Double.pi * 0.23 * t + 1))
        let chew = pow(max(0, Float(sin(2 * Double.pi * 1.5 * t))), 2)
        var pose = MouthPose()
        pose.J = 0.03 + 0.10 * chew
        pose.pucker = 0.22 + 0.10 * purse
        pose.smile = SIMD2(max(0, 0.45 * side), max(0, -0.45 * side))
        pose.rollLower = 0.15 + 0.2 * (1 - chew)
        pose.shift = 0.04 * side
        pose.slide = 1
        return pose
    }

    /// The head while thinking: a held tilt, turning a little with the chew's drift (pitch, roll, yaw).
    nonisolated static func thinkingHead(_ t: Double) -> SIMD3<Float> {
        SIMD3(1.5, 4, 3 * Float(sin(2 * Double.pi * 0.42 * t)))
    }

    /// The pose, head and squash for a turn's last moment.
    nonisolated static func reaction(_ r: MouthReaction) -> (pose: MouthPose, head: SIMD3<Float>, squash: Float) {
        var pose = MouthPose()
        pose.slide = 1
        switch r {
        case .done:          // a pleased grin, teeth showing
            pose.J = 0.16; pose.part = 1; pose.wide = 0.8
            pose.smile = SIMD2(1.6, 1.6); pose.upperUp = SIMD2(0.6, 0.6)
            return (pose, SIMD3(-2, 0, 0), -0.04)
        case .cancel:        // an "eek": both rows bared, corners pulled down
            pose.J = 0.14; pose.part = 1; pose.wide = 0.8
            pose.smile = SIMD2(-1.2, -1.2); pose.upperUp = SIMD2(0.5, 0.5); pose.lowerDown = SIMD2(1.6, 1.6)
            return (pose, SIMD3(3, 0, 0), 0.03)
        }
    }
}

/// The Loud Mouth, drawn live with Metal. Transparent around the lips; ignores the mouse.
struct MouthView: NSViewRepresentable {
    var mode: MouthMode
    var live: MouthLive?

    func makeNSView(context: Context) -> NSView {
        guard let (asset, renderer) = MouthStage.shared.prepare() else { return NSView() }
        return MouthMetalView(asset: asset, renderer: renderer)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? MouthMetalView else { return }
        view.frames.set(mode: mode, live: live)
    }
}

/// Hosts the mouth's Metal layer. The frames themselves are drawn on `MouthRenderThread`, never
/// on main: main carries the Yapper key's event tap and every step from release to paste, and
/// drawing there (as an MTKView does) blocked it for up to ~13 ms a frame waiting on a drawable.
final class MouthMetalView: NSView {
    let frames: MouthFrames
    private let metalLayer = CAMetalLayer()

    init(asset: MouthAsset, renderer: MouthRenderer) {
        frames = MouthFrames(asset: asset, renderer: renderer, layer: metalLayer)
        super.init(frame: CGRect(origin: .zero, size: MouthStage.viewSize))
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = MouthRenderer.colorFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        wantsLayer = true
        // the mouth sits on the pill: a soft shadow under it, as in the mockups
        metalLayer.shadowColor = NSColor.black.cgColor
        metalLayer.shadowOpacity = 0.3
        metalLayer.shadowRadius = 3
        metalLayer.shadowOffset = CGSize(width: 0, height: -2)
        fitDrawable()
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { frames.setRunning(false) }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitDrawable()
        frames.setRunning(window != nil)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fitDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitDrawable()
    }

    private func fitDrawable() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        metalLayer.contentsScale = scale
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        frames.refresh()
    }
}

/// Decides what the mouth does each frame: acts out the voice while you talk, chews while the words
/// are worked out, grins or grimaces at the end, and eases from one to the next. Pure: given the
/// same frame times and drives it always does the same, so the film probe sees exactly the app.
struct MouthDirector {
    struct Frame { var pose: MouthPose; var head: SIMD3<Float>; var squash: Float; var dt: Float }

    /// How long a change of mode takes to ease over.
    static let modeEase: CFTimeInterval = 0.26

    private var born: CFTimeInterval?
    private var last: CFTimeInterval?
    private var performance = MouthPerformance()
    private var smoother = MouthDriveSmoother()
    /// The jaw goes pose to pose; width and teeth ease on a spring.
    private var jawMoves = MouthMoveFollower()
    /// The lips act out the viseme net's shapes, when it runs.
    private var shaper = MouthShaper()
    /// The last frame (pose, head turn, squash), and the mode it was made in.
    private struct Shown { var pose = MouthPose(), head = SIMD3<Float>.zero, squash: Float = 0 }
    private var shown = Shown()
    private var shownMode: MouthMode?
    private var easeIn: (from: Shown, start: CFTimeInterval)?
    /// How long the voice has been quiet at the mouth's playhead.
    private var quiet: Double = 0
    /// How much further behind the voice the mouth is playing than usual. A pause plays slowly to
    /// build this up, so the mouth can see the next word coming and draw a breath before it; the
    /// first words then play a little fast until it's caught up again.
    private var behind: Double = 0
    /// How far into a breath the mouth is (0…1); it fades as the first word lands rather than snapping.
    private var breath: Float = 0

    /// Silence after speech this long closes the jaw.
    static let closeAfter: Double = 0.08
    /// A pause this long starts slowing down, building up to `breathLead` of look-ahead.
    static let slowAfter: Double = 0.3, breathLead: Double = 0.15
    /// The lips as the mouth arrives on the pill: pressed together, about to speak.
    static let arriving = MouthPose(slide: 1, rollUpper: 0.5, rollLower: 0.5)

    /// The mouth went off screen: the next frame starts fresh.
    mutating func stop() { last = nil; shownMode = nil; easeIn = nil; quiet = 0; behind = 0; breath = 0 }

    /// The frame that reaches the screen at host time `now`; `drive` reads the voice at a host time.
    mutating func frame(mode: MouthMode, at now: CFTimeInterval, drive: (CFTimeInterval) -> MouthDrive) -> Frame {
        if born == nil { born = now }
        let t = now - born!
        var dt = last.map { Float(min(0.1, max(0, now - $0))) } ?? 0
        if last != nil, dt == 0 { dt = 1e-4 }          // a repeated frame: hold, don't reset the springs
        last = now
        var pose: MouthPose
        var head = SIMD3<Float>.zero, squash: Float = 0
        switch mode {
        case .live:
            if shownMode != .live { smoother.reset(); jawMoves.reset(); shaper.reset(); quiet = 0; behind = 0; breath = 0 }
            let playhead = now - behind
            let raw = drive(playhead)
            quiet = raw.speaking > 0.5 ? 0 : quiet + Double(dt)
            // a pause plays at half speed until the mouth can see `breathLead` ahead; speech at 1.2x
            // until it's caught up. Nothing moves in a pause, so the slow-down never shows.
            if quiet > Self.slowAfter { behind = min(Self.breathLead, behind + 0.5 * Double(dt)) }
            else if quiet == 0 { behind = max(0, behind - 0.2 * Double(dt)) }
            var d = smoother.step(raw, dt: dt)
            // in a pause the jaw closes in one move, rather than fading for as long as the pause lasts
            d.J = jawMoves.step(quiet > Self.closeAfter ? 0 : raw.J, dt: dt)
            // with the viseme net running, its shapes set the lips; the reader's jaw still sets how open
            let lips = raw.hasShape ? shaper.step(raw.shape, dt: dt) : nil
            if lips == nil { shaper.reset() }
            let acted = performance.step(J: d.J, W: lips?.W ?? d.W, T: d.T, dt: dt)
            pose = acted.pose; head = acted.head; squash = acted.squash
            if let lips { MouthShaper.apply(close: lips.close, fv: lips.fv, part: lips.part, to: &pose) }
            // a breath before the next words: the lips part and the head lifts as the first word nears
            var lead: Double?
            if quiet > Self.slowAfter {
                for k in stride(from: 0.01, through: behind, by: 0.01) where drive(playhead + k).speaking > 0.5 { lead = k; break }
            }
            let u = lead.map { Float(1 - $0 / Self.breathLead) } ?? 0
            let want = u * u * (3 - 2 * u)
            breath = want >= breath ? want : breath * exp(-dt / 0.08)     // fades as the words take over
            if breath > 0.001 {
                let b = breath
                pose.J += 0.07 * b; pose.part += 0.5 * b
                pose.rollUpper -= 0.15 * b; pose.rollLower -= 0.15 * b
                pose.upperUp += SIMD2(repeating: 0.12 * b)
                head.x -= 1.5 * b; squash += 0.03 * b
            }
        case .thinking:
            pose = MouthStage.thinking(t)
            head = MouthStage.thinkingHead(t)
        case .reacting(let r):
            (pose, head, squash) = MouthStage.reaction(r)
        case .still(let p):
            pose = p; dt = 0
        }
        // a change of mode (talking, thinking, the grin) eases over from the last frame
        if case .still = mode { easeIn = nil } else {
            if shownMode != mode {
                if let _ = shownMode { easeIn = (from: shown, start: now) }
                // arriving on the pill to listen: lips pressed, then they part into the voice
                else if case .live = mode { easeIn = (from: Shown(pose: Self.arriving, squash: -0.04), start: now) }
                else { easeIn = nil }
            }
            if let e = easeIn {
                let u = Float(min(1, (now - e.start) / Self.modeEase))
                if u >= 1 { easeIn = nil } else {
                    let k = u * u * (3 - 2 * u)                     // smoothstep: leaves and lands softly
                    pose = MouthPose.mix(e.from.pose, pose, k)
                    head = e.from.head + (head - e.from.head) * k
                    squash = e.from.squash + (squash - e.from.squash) * k
                }
            }
        }
        shown = Shown(pose: pose, head: head, squash: squash)
        shownMode = mode
        return Frame(pose: pose, head: head, squash: squash, dt: dt)
    }
}

/// Draws one mouth into its layer on `MouthRenderThread`: live and thinking frames on a
/// CAMetalDisplayLink, which hands over a drawable that's ready, and a still pose once each time it
/// changes. `set`, `setRunning` and `refresh` may be called from anywhere; the rest runs on that
/// thread.
final class MouthFrames: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private let renderer: MouthRenderer
    private let model: MouthModel
    private let layer: CAMetalLayer
    private let rest: SIMD3<Float>

    // written by the view, read by the render thread
    private let lock = NSLock()
    private var mode: MouthMode = .live
    private var live: MouthLive?
    private var running = false

    // the render thread's own
    private var link: CAMetalDisplayLink?
    private var director = MouthDirector()
    private var msaa: MTLTexture?
    private var depth: MTLTexture?

    init(asset: MouthAsset, renderer: MouthRenderer, layer: CAMetalLayer) {
        self.renderer = renderer
        self.layer = layer
        model = MouthModel(asset: asset, springs: 0.5)
        rest = asset.view.rotationDegrees
    }

    func set(mode: MouthMode, live: MouthLive?) {
        lock.lock()
        let changed = mode != self.mode
        self.mode = mode
        self.live = live
        lock.unlock()
        if changed { refresh() }
    }

    func setRunning(_ on: Bool) {
        lock.lock(); running = on; lock.unlock()
        refresh()
    }

    /// Re-reads the state on the render thread: starts or stops the display link, redraws a still.
    func refresh() { MouthRenderThread.shared.run { self.sync() } }

    private func sync() {
        lock.lock(); let mode = self.mode, running = self.running; lock.unlock()
        let still: Bool
        if case .still = mode { still = true } else { still = false }
        if running && !still {
            guard link == nil else { return }
            let l = CAMetalDisplayLink(metalLayer: layer)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 240, preferred: 240)   // the screen's full rate: 120 on ProMotion, 144 on a gaming monitor
            l.delegate = self
            l.add(to: .current, forMode: .default)
            link = l
        } else {
            link?.invalidate()
            link = nil
            director.stop()                     // the next showing starts fresh, not eased from this one
            if running, still, let drawable = layer.nextDrawable() { render(drawable, at: CACurrentMediaTime()) }
        }
    }

    /// Each frame is posed for the moment it reaches the screen, not the moment it happens to be
    /// drawn: drawing starts a little early or late frame to frame, and posing by that jitters.
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        render(update.drawable, at: update.targetPresentationTimestamp)
    }

    private func render(_ drawable: CAMetalDrawable, at now: CFTimeInterval) {
        lock.lock(); let mode = self.mode, live = self.live; lock.unlock()
        let target = drawable.texture
        guard let pass = pass(into: target), let commands = renderer.queue.makeCommandBuffer() else { return }
        let frame = director.frame(mode: mode, at: now) { live?.drive(at: $0) ?? .rest }
        var framing = MouthFraming(rotationDegrees: rest + frame.head)
        framing.squash = frame.squash
        model.pose(frame.pose, dt: frame.dt)
        guard renderer.encode(model, framing: framing, size: CGSize(width: target.width, height: target.height),
                              pass: pass, into: commands) else { return }   // GPU behind: skip this frame
        commands.present(drawable)
        commands.commit()
    }

    /// A pass that draws multisampled into `target`, remaking the MSAA and depth targets when its
    /// size changes. Earlier frames still in flight are fine: one queue runs them in order.
    private func pass(into target: MTLTexture) -> MTLRenderPassDescriptor? {
        let samples = renderer.sampleCount
        if depth?.width != target.width || depth?.height != target.height {
            func texture(_ format: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: target.width,
                                                                 height: target.height, mipmapped: false)
                d.textureType = samples > 1 ? .type2DMultisample : .type2D
                d.sampleCount = samples
                d.usage = .renderTarget
                d.storageMode = .private
                return renderer.device.makeTexture(descriptor: d)
            }
            msaa = samples > 1 ? texture(MouthRenderer.colorFormat) : nil
            depth = texture(MouthRenderer.depthFormat)
        }
        guard let depth, samples == 1 || msaa != nil else { return nil }
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = msaa ?? target
        color.resolveTexture = msaa == nil ? nil : target
        color.loadAction = .clear
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        color.storeAction = msaa == nil ? .store : .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        return pass
    }
}

/// The one thread every on-screen mouth draws on, so the shared renderer is only ever driven from
/// one place, and never from main.
final class MouthRenderThread: @unchecked Sendable {
    static let shared = MouthRenderThread()
    private var loop: CFRunLoop?

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            loop = CFRunLoopGetCurrent()
            RunLoop.current.add(Port(), forMode: .default)     // keeps the loop alive while idle
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "app.yapper.mouth.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func run(_ work: @escaping @Sendable () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(loop)
    }
}
