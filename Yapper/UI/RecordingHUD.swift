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
        case done(TurnReport.Outcome)
    }

    static let barCount = 18

    @Published var phase: Phase = .hidden
    /// The last `barCount` mic levels, 0…1, oldest first.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: barCount)

    func push(level rms: Float) {
        levels.removeFirst()
        levels.append(Self.normalized(rms))
    }

    func resetLevels() { levels = Array(repeating: 0, count: Self.barCount) }

    /// RMS → 0…1 on a decibel scale: a quiet room sits near the floor, normal speech fills
    /// most of the bar, shouting tops out.
    nonisolated static func normalized(_ rms: Float) -> CGFloat {
        let db = 20 * log10(max(Double(rms), 1e-7))
        return CGFloat(min(1, max(0, (db + 58) / 40)))
    }
}

/// A small pill at the bottom of the screen while Voice In runs: it opens out of a dot into the
/// live waveform while you talk, the bars settle into a slow ripple while the words are worked
/// out, and it closes back into the dot when they land. Never takes focus or clicks,
/// so it can't steal the paste or swallow a click aimed at what's underneath.
@MainActor
final class RecordingHUDController {
    let model = RecordingHUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private weak var state: AppState?

    /// The pill plus room for its shadow. The panel ignores the mouse, so the margin is free.
    static let panelSize = NSSize(width: 280, height: 84)

    init(state: AppState) {
        self.state = state
        let voice = state.voiceInput
        voice.$state.removeDuplicates()
            .combineLatest(voice.$isLocked.removeDuplicates())
            .sink { [weak self] s, locked in self?.update(state: s, locked: locked) }
            .store(in: &cancellables)
    }

    var enabled: Bool { state?.settings.dictationHUD ?? true }

    func level(_ rms: Float) {
        guard enabled, case .listening = model.phase else { return }
        model.push(level: rms)
    }

    /// The turn reported how it ended. Words that landed need no word from the pill: it just
    /// closes. Anything else says so for a moment, then goes.
    func finish(_ outcome: TurnReport.Outcome) {
        guard enabled, panel?.isVisible == true || model.phase != .hidden else { return }
        if outcome == .pasted { hide(); return }
        hideTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { model.phase = .done(outcome) }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func update(state: VoiceInputCoordinator.State, locked: Bool) {
        guard enabled else { hide(); return }
        switch state {
        case .listening(let mode):
            hideTask?.cancel()
            if case .listening = model.phase {} else { model.resetLevels() }
            show()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                model.phase = .listening(locked: locked, handsFree: mode == .handsFree)
            }
        case .transcribing:
            hideTask?.cancel()
            show()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.phase = .transcribing }
        case .idle:
            // A turn that ended with an outcome is showing it; anything else (an accidental
            // hold, a cancelled one, hands-free closing on silence) just goes.
            if case .done = model.phase { return }
            hide()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard model.phase != .hidden else { return }
        withAnimation(.timingCurve(0.5, 0, 0.8, 0.4, duration: 0.26)) { model.phase = .hidden }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.32))
            guard let self, !Task.isCancelled, self.model.phase == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// Bottom centre of the screen you're working on, just above the Dock.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let size = Self.panelSize
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 6, width: size.width, height: size.height),
                       display: false)
    }

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
                    RecordingPill(phase: model.phase, levels: model.levels, shadow: false)
                        .transition(.pillOpen)
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .padding(.bottom, 14)
        }
        .frame(width: RecordingHUDController.panelSize.width, height: RecordingHUDController.panelSize.height)
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
    let levels: [CGFloat]
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
        case .listening, .transcribing, .done(.pasted):
            Waveform(levels: levels, working: phase != .listening(locked: locked, handsFree: handsFree))
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
        case .done(let outcome):
            DoneMark(outcome: outcome)
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

/// The mic level as bars, newest on the right, mirrored about the centre line. While the words
/// are worked out the same bars ease down into a slow ripple running left to right, so the pill
/// keeps its shape from talking to typing.
private struct Waveform: View {
    let levels: [CGFloat]
    let working: Bool
    @State private var workingSince: Date?

    private static let settle: TimeInterval = 0.35

    var body: some View {
        TimelineView(.animation(paused: !working)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let blend = blend(at: timeline.date)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    let ripple = pow(max(0, sin(t * 2 * .pi * 0.9 - Double(i) * 0.42)), 2)
                    let fade = 0.4 + 0.6 * Double(i) / Double(max(1, levels.count - 1))
                    Capsule()
                        .fill(.white.opacity(mix(fade, 0.45 + 0.5 * ripple, blend)))
                        .frame(width: 2.5, height: mix(3 + level * 15, 3 + 5 * ripple, blend))
                }
            }
        }
        .frame(height: 18)
        .animation(working ? nil : .easeOut(duration: 0.12), value: levels)
        .onChange(of: working) { _, now in workingSince = now ? Date() : nil }
    }

    /// 0 shows the live levels, 1 the ripple. A pill that starts out working (a preview) is
    /// already settled.
    private func blend(at now: Date) -> Double {
        guard working else { return 0 }
        guard let since = workingSince else { return 1 }
        let x = min(1, max(0, now.timeIntervalSince(since) / Self.settle))
        return x * x * (3 - 2 * x)
    }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private func mix(_ a: CGFloat, _ b: Double, _ t: Double) -> CGFloat { a + (CGFloat(b) - a) * CGFloat(t) }
}

private struct DoneMark: View {
    let outcome: TurnReport.Outcome
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
    }

    private var symbol: String {
        switch outcome {
        case .pasted: "checkmark"
        case .copied: "doc.on.clipboard"
        case .empty: "ear.trianglebadge.exclamationmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    private var tint: Color {
        if case .failed = outcome { return Brand.red }
        return .white
    }
    private var label: String {
        switch outcome {
        case .pasted: "Typed"
        case .copied: "On the clipboard"
        case .empty: "Didn’t catch that"
        case .failed: "Couldn’t transcribe"
        }
    }
}
