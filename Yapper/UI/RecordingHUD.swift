import AppKit
import SwiftUI
import Combine

/// What the recording pill is showing.
@MainActor
final class RecordingHUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(locked: Bool, handsFree: Bool)
        case transcribing
    }

    @Published var phase: Phase = .hidden
    /// The mic level the bars follow, eased every frame.
    let motion = PillMotion()

    func push(level rms: Float) { motion.hear(db: 20 * log10(max(Double(rms), 1e-7))) }

    func resetLevels() { motion.reset() }
}

/// The waveform's moving parts, stepped once per display frame rather than once per mic buffer
/// (about 12 a second), so the bars glide instead of stepping. Not observed: the waveform's
/// TimelineView redraws every frame anyway.
@MainActor
final class PillMotion {
    /// Loudness the bars are heading for, and where they are now, 0…1.
    private(set) var target: CGFloat = 0
    private(set) var level: CGFloat = 0
    /// 0 while you talk, 1 once the words are being worked out.
    private(set) var work: CGFloat = 0
    /// The quietest the mic has been this turn, so a noisy room or a hot mic still reads.
    private var floor: Double = -50
    private var last: TimeInterval?

    /// Rising follows the voice closely; falling lets go a little slower, so words don't flicker.
    static let attack: Double = 0.05, release: Double = 0.16, settle: Double = 0.28

    init(fixed: CGFloat? = nil, working: Bool = false) {
        if let fixed { target = fixed; level = fixed }
        work = working ? 1 : 0
    }

    func hear(db: Double) {
        floor = max(-62, min(floor, db))
        floor += 0.15                     // drift back up, so one quiet moment doesn't pin it
        target = CGFloat(min(1, max(0, (db - floor - 4) / 24)))
    }

    func reset() { target = 0; level = 0; work = 0; floor = -50; last = nil }

    /// Moves everything on to `now` and returns the current level and work blend.
    func step(to now: TimeInterval, working: Bool) -> (level: CGFloat, work: CGFloat) {
        let dt = last.map { min(0.1, max(0, now - $0)) } ?? 0
        last = now
        let goal: CGFloat = working ? 0 : target
        let tau = goal > level ? Self.attack : Self.release
        level += (goal - level) * CGFloat(1 - exp(-dt / tau))
        work += ((working ? 1 : 0) - work) * CGFloat(1 - exp(-dt / Self.settle))
        return (level, work)
    }
}

/// A small pill at the bottom of the screen while Voice In runs: it opens out of a dot into the
/// live waveform while you talk, the bars settle into a slow ripple while the words are worked
/// out, and it closes back into the dot when the turn ends, however it ended (the sounds say
/// how). Never takes focus or clicks, so it can't steal the paste or swallow a click aimed at
/// what's underneath.
@MainActor
final class RecordingHUDController {
    let presenter = RecordingHUDPresenter()
    private var cancellables: Set<AnyCancellable> = []
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
        let voice = state.voiceInput
        voice.$state.removeDuplicates()
            .combineLatest(voice.$isLocked.removeDuplicates(), voice.$priming.removeDuplicates())
            .sink { [weak self] s, locked, priming in self?.update(state: s, locked: locked, priming: priming) }
            .store(in: &cancellables)
    }

    var enabled: Bool { state?.settings.dictationHUD ?? true }

    func level(_ rms: Float) {
        guard enabled else { return }
        presenter.level(rms)
    }

    /// The turn reported how it ended. The pill doesn't spell it out; it just closes.
    func finish(_ outcome: TurnReport.Outcome) { presenter.close() }

    private func update(state: VoiceInputCoordinator.State, locked: Bool, priming: Bool) {
        guard enabled else { presenter.close(); return }
        // The mic opened at key-down: the pill opens now, as if this were already a hold. A tap
        // ends the priming with the state still idle, and the pill closes again below.
        if priming, state == .idle {
            presenter.listen(locked: false, handsFree: false)
            return
        }
        switch state {
        case .listening(let mode): presenter.listen(locked: locked, handsFree: mode == .handsFree)
        case .transcribing: presenter.work()
        case .idle: presenter.close()
        }
    }
}

/// Puts the pill on screen and moves it between phases. Every animation the pill makes starts
/// here, so the probe that records it drives exactly what the app does.
@MainActor
final class RecordingHUDPresenter {
    let model = RecordingHUDModel()
    private var panel: NSPanel?

    /// The pill plus room for its shadow. The panel ignores the mouse, so the margin is free.
    static let panelSize = NSSize(width: 280, height: 84)

    func level(_ rms: Float) {
        guard case .listening = model.phase else { return }
        model.push(level: rms)
    }

    /// Opening: a quick start and a long soft landing, no bounce. Closing: eases in and goes.
    static let opening = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.28)
    static let closing = Animation.timingCurve(0.4, 0, 0.6, 1, duration: 0.16)

    init() {
        // The panel goes up once, empty, and stays: ordering a window in at the moment the pill
        // opens costs the first few frames of the animation.
        show()
    }

    func listen(locked: Bool, handsFree: Bool) {
        let opening = model.phase == .hidden
        if case .listening = model.phase {} else if case .transcribing = model.phase {} else { model.resetLevels() }
        show()
        withAnimation(opening ? Self.opening : .easeOut(duration: 0.18)) {
            model.phase = .listening(locked: locked, handsFree: handsFree)
        }
    }

    /// The bars ease down and pulse on their own clock; the pill itself doesn't change.
    func work() {
        show()
        model.phase = .transcribing
    }

    func close() {
        guard model.phase != .hidden else { return }
        withAnimation(Self.closing) { model.phase = .hidden }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if model.phase == .hidden { position(panel) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Bottom centre of the screen you're working on, just above the Dock.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let size = Self.panelSize
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 6, width: size.width, height: size.height),
                       display: false)
    }

    /// Where the pill sits on screen, for the probe that records it.
    var frame: NSRect? { panel?.frame }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: RecordingHUDView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }
}

// MARK: - View

/// The pill itself: an ink capsule that reads on any wallpaper with white bars. It opens out of
/// a dot and closes back into one.
struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            // The shadow sits outside the opening mask, so it follows the pill as it grows.
            ZStack {
                if model.phase != .hidden {
                    RecordingPill(phase: model.phase, motion: model.motion, shadow: false)
                        .transition(.pillOpen)
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .padding(.bottom, 14)
        }
        .frame(width: RecordingHUDPresenter.panelSize.width, height: RecordingHUDPresenter.panelSize.height)
    }
}

/// Reveals the pill from a dot at its centre outwards, rather than zooming the whole thing, so
/// the bars inside never squash. `open` runs from 0 (a dot) to 1.
struct PillOpen: ViewModifier {
    let open: CGFloat
    func body(content: Content) -> some View {
        content
            .mask { Capsule(style: .continuous).scaleEffect(x: 0.16 + 0.84 * open, y: 0.85 + 0.15 * open) }
            .scaleEffect(0.82 + 0.18 * open, anchor: .bottom)
            .opacity(Double(min(1, open * 1.6)))
    }
}

private extension AnyTransition {
    static var pillOpen: AnyTransition {
        .modifier(active: PillOpen(open: 0), identity: PillOpen(open: 1))
    }
}

/// The pill's face for one phase. Shared by the HUD and the preview in Settings → Voice in.
struct RecordingPill: View {
    let phase: RecordingHUDModel.Phase
    let motion: PillMotion
    var shadow = true

    var body: some View {
        HStack(spacing: 9) { content }
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(Brand.ink.opacity(0.94)))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(shadow ? 0.28 : 0), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
    }

    /// One waveform across talking and working, so its bars carry over instead of being swapped.
    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .listening, .transcribing:
            Waveform(motion: motion, working: phase == .transcribing)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else if handsFree {
                Image(systemName: "ear")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var locked: Bool {
        if case .listening(let locked, _) = phase { return locked }
        return false
    }
    private var handsFree: Bool {
        if case .listening(_, let handsFree) = phase { return handsFree }
        return false
    }
}

/// A row of bars, tallest in the middle, scaled by the eased mic level with a slow wobble
/// running across them so even a steady voice looks alive. When you let go the level eases to
/// rest and a soft pulse runs left to right while the words are worked out. Drawn every frame.
private struct Waveform: View {
    let motion: PillMotion
    let working: Bool

    static let count = 13
    static let barWidth: CGFloat = 2.5, gap: CGFloat = 2.5
    static let rest: CGFloat = 3, tall: CGFloat = 18

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let (level, work) = motion.step(to: t, working: working)
            let bars = (0..<Self.count).map { Self.bar($0, t: t, level: level, work: work) }
            Canvas { context, size in
                for (i, bar) in bars.enumerated() {
                    let x = CGFloat(i) * (Self.barWidth + Self.gap)
                    let rect = CGRect(x: x, y: (size.height - bar.height) / 2, width: Self.barWidth, height: bar.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                                 with: .color(.white.opacity(bar.opacity)))
                }
            }
        }
        .frame(width: CGFloat(Self.count) * (Self.barWidth + Self.gap) - Self.gap, height: Self.tall)
    }

    private static func bar(_ i: Int, t: Double, level: CGFloat, work: CGFloat) -> (height: CGFloat, opacity: Double) {
        let mid = Double(count - 1) / 2
        let d = (Double(i) - mid) / mid                      // -1 … 1
        let shape = 1 - 0.55 * d * d                         // tallest in the middle
        // Two slow waves at odd rates, running across the bars, so it never visibly loops.
        let wobble = 0.72 + 0.2 * sin(2 * .pi * (1.1 * t - Double(i) * 0.09))
                          + 0.1 * sin(2 * .pi * (1.9 * t + Double(i) * 0.23))
        let voice = (tall - rest) * level * CGFloat(shape * wobble)
        // The working pulse: a soft hump travelling left to right about once a second.
        let phase = (0.85 * t).truncatingRemainder(dividingBy: 1) * 1.36 - 0.18
        let dist = (Double(i) / Double(count - 1)) - phase
        let pulse = exp(-dist * dist / 0.025)
        let height = rest + voice + 5 * work * CGFloat(pulse)
        let opacity = 0.95 - 0.4 * Double(work) * (1 - pulse)
        return (min(tall, height), opacity)
    }
}
