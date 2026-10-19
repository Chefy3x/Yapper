import SwiftUI
import MetalKit

/// What the mouth is doing on screen.
enum MouthMode: Equatable {
    /// Lip-syncing the mic, live.
    case live
    /// The words are being worked out: lips pressed, a slow sideways purse.
    case thinking
    /// Held still in one pose (Settings' preview).
    case still(MouthPose)
}

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

    /// The thinking loop at `t` seconds.
    static func thinking(_ t: Double) -> MouthPose {
        let side = Float(sin(2 * Double.pi * 0.42 * t))
        let purse = Float(sin(2 * Double.pi * 0.23 * t + 1))
        var pose = MouthPose()
        pose.J = 0.02
        pose.pucker = 0.2 + 0.08 * purse
        pose.smile = SIMD2(max(0, 0.4 * side), max(0, -0.4 * side))
        pose.rollLower = 0.15
        return pose
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
        view.live = live
        view.mode = mode
    }
}

final class MouthMetalView: MTKView, MTKViewDelegate {
    var live: MouthLive?
    var mode: MouthMode = .live {
        didSet {
            guard mode != oldValue else { return }
            if case .still = mode { isPaused = true; enableSetNeedsDisplay = true; needsDisplay = true }
            else { enableSetNeedsDisplay = false; isPaused = false }
        }
    }
    private let renderer: MouthRenderer
    private let model: MouthModel
    private var last: CFTimeInterval?
    private let born = CACurrentMediaTime()

    init(asset: MouthAsset, renderer: MouthRenderer) {
        self.renderer = renderer
        model = MouthModel(asset: asset, springs: 0.5)
        super.init(frame: CGRect(origin: .zero, size: MouthStage.viewSize), device: renderer.device)
        colorPixelFormat = MouthRenderer.colorFormat
        depthStencilPixelFormat = MouthRenderer.depthFormat
        sampleCount = renderer.sampleCount
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 60
        framebufferOnly = true
        layer?.isOpaque = false
        // the mouth sits on the pill: a soft shadow under it, as in the mockups
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        delegate = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let began = CACurrentMediaTime()
        defer {
            // this runs on the main thread, which also carries the Yapper key's event tap
            let ms = (CACurrentMediaTime() - began) * 1000
            if ms > 12 { Log.app.notice("Loud Mouth frame took \(String(format: "%.1f", ms), privacy: .public) ms") }
        }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commands = renderer.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let t = now - born
        var dt = last.map { Float(min(0.1, now - $0)) } ?? 0
        last = now
        var head = SIMD3<Float>(6, 0, -12 + 2 * Float(sin(0.7 * t)))   // a slow, small sway
        let pose: MouthPose
        switch mode {
        case .live:
            let d = live?.drive(at: now) ?? .rest
            pose = .voice(J: d.J, W: d.W, T: d.T)
            head.x += 1.5 * d.J
        case .thinking:
            pose = MouthStage.thinking(t)
        case .still(let p):
            pose = p; dt = 0; head = SIMD3(6, 0, -12)
        }
        model.pose(pose, dt: dt)
        guard renderer.encode(model, framing: MouthFraming(rotationDegrees: head), size: drawableSize,
                              pass: pass, into: commands) else { return }   // GPU behind: skip this frame
        commands.present(drawable)
        commands.commit()
    }
}
