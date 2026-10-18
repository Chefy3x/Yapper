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

/// A small pill at the bottom of the screen while Voice In runs: live mic level while you talk,
/// a sweep while the words are worked out, a tick when they land. Never takes focus or clicks,
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

    /// The turn reported how it ended; the pill says so for a moment, then goes.
    func finish(_ outcome: TurnReport.Outcome) {
        guard enabled, panel?.isVisible == true || model.phase != .hidden else { return }
        hideTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { model.phase = .done(outcome) }
        let linger: Double = outcome == .pasted ? 0.7 : 1.6
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(linger))
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
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
        withAnimation(.easeIn(duration: 0.18)) { model.phase = .hidden }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.22))
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

/// The pill itself, in the tape-label palette: neutral charcoal, cream marks, the REC red dot
/// as the only colour while the mic is open.
struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if model.phase != .hidden {
                pill
                    .padding(.bottom, 14)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
                                            removal: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)))
            }
        }
        .frame(width: RecordingHUDController.panelSize.width, height: RecordingHUDController.panelSize.height)
    }

    private var pill: some View {
        RecordingPill(phase: model.phase, levels: model.levels)
    }
}

/// The pill's face for one phase. Shared by the HUD and the preview in Settings → Voice in.
struct RecordingPill: View {
    let phase: RecordingHUDModel.Phase
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 9) { content }
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [Tape.panelHi, Tape.void], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule(style: .continuous).strokeBorder(Tape.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .listening(let locked, let handsFree):
            RecDot()
            LevelBars(levels: levels)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tape.cream.opacity(0.85))
            } else if handsFree {
                Image(systemName: "ear")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tape.dust)
            }
        case .transcribing:
            TranscribingSweep()
        case .done(let outcome):
            DoneMark(outcome: outcome)
        }
    }
}

private struct RecDot: View {
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(Tape.recRedHot)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// The last couple of seconds of mic level, newest on the right, mirrored about the centre line.
private struct LevelBars: View {
    let levels: [CGFloat]
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                Capsule()
                    .fill(Tape.cream.opacity(0.35 + 0.55 * Double(i) / Double(max(1, levels.count - 1))))
                    .frame(width: 2.5, height: 3 + level * 15)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// Five dots taking turns: the words are being worked out.
private struct TranscribingSweep: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    let phase = sin((t * 2 * .pi * 1.1) - Double(i) * 0.75)
                    Circle()
                        .fill(Tape.cream.opacity(0.35 + 0.55 * max(0, phase)))
                        .frame(width: 4.5, height: 4.5)
                        .offset(y: -2.5 * max(0, phase))
                }
            }
            .frame(width: 70, height: 18)
        }
    }
}

private struct DoneMark: View {
    let outcome: TurnReport.Outcome
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            if let label {
                Text(label)
                    .font(Tape.mono(10.5, .semibold))
                    .foregroundStyle(Tape.cream.opacity(0.9))
                    .lineLimit(1)
            }
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
        if case .failed = outcome { return Tape.recRedHot }
        return Tape.cream
    }
    private var label: String? {
        switch outcome {
        case .pasted: nil
        case .copied: "On the clipboard"
        case .empty: "Didn’t catch that"
        case .failed: "Couldn’t transcribe"
        }
    }
}
