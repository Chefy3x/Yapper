import AppKit
import Combine
import SwiftUI

/// What the note under the pill is saying.
@MainActor
final class VoiceToastModel: ObservableObject {
    enum Kind: Hashable {
        /// Words learned from an edit you made, now in your dictionary.
        case learned([String])
        /// A dictation's paste went nowhere; the words are waiting.
        case missedPaste
        case pasting
        case pasted
        case copied
        /// Pasting again didn't land either; the words are on the clipboard now.
        case stillMissed
    }

    @Published var kind: Kind?
}

/// A note where the pill sits, after a turn: a word learned from your edit (with Undo), or a
/// paste that went nowhere (with Paste and Copy, and word of whether that worked). The one part of
/// Voice In you can click, so it's its own panel, on screen only while there's something to say.
/// Clicking it never takes focus from the app you were typing in, which is what lets Paste land
/// in the field you just clicked.
@MainActor
final class VoiceToastPresenter {
    let model = VoiceToastModel()
    var onUndoLearned: (() -> Void)?
    /// Types the words into whatever is focused; true when the app took them.
    var onPaste: ((String) async -> Bool)?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// The words a missed paste is holding.
    private var pending: String?
    /// The pill is on screen, so the note sits above it rather than on it.
    private var pillUp = false
    private var pillWatch: AnyCancellable?

    static let panelSize = NSSize(width: 480, height: 64)
    /// How far the note rises while the pill is up: from the pill's bottom edge to the top of its
    /// panel, which leaves the mouth its room.
    static let lift = RecordingHUDPresenter.panelSize.height - RecordingHUDPresenter.pillInset

    /// Keeps the note off the pill. A word learned from your last edit turns up as the next
    /// dictation opens the pill, so the two do meet: the note rides above while the pill is up and
    /// settles back when it closes.
    func follow(_ pill: RecordingHUDModel) {
        pillWatch = pill.$phase
            .map { $0 != .hidden }
            .removeDuplicates()
            .sink { [weak self] up in self?.pillMoved(up: up) }
    }

    private func pillMoved(up: Bool) {
        pillUp = up
        guard let panel, panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(Self.frame(in: screen.visibleFrame, lifted: up), display: true)
        }
    }

    func learned(_ words: [String]) {
        guard !words.isEmpty else { return }
        show(.learned(words), for: 6)
    }

    /// Waits for the pill's reaction to finish and the pill to close (0.4 s + 0.16 s), then offers
    /// the words back in its place.
    func missedPaste(_ text: String) {
        guard !text.isEmpty else { return }
        pending = text
        show(.missedPaste, for: 30, after: 0.6)
    }

    /// Paste the held words (or `text`) into whatever is focused, and say whether it landed.
    func paste(_ text: String? = nil) {
        guard let words = text ?? pending, let onPaste else { return }
        show(.pasting, for: nil)
        Task { [weak self] in
            let landed = await onPaste(words)
            guard let self else { return }
            if landed {
                self.pending = nil
                self.show(.pasted, for: 1.6)
            } else {
                Self.putOnClipboard(words)
                self.pending = nil
                self.show(.stillMissed, for: 8)
            }
        }
    }

    func copy() {
        guard let words = pending else { return }
        Self.putOnClipboard(words)
        pending = nil
        show(.copied, for: 2.5)
    }

    func undoLearned() {
        onUndoLearned?()
        close()
    }

    /// A new dictation is starting, or the note was dismissed.
    func close() {
        hideTask?.cancel()
        hideTask = nil
        guard model.kind != nil else { return }
        withAnimation(.easeIn(duration: 0.14)) { model.kind = nil }
        let panel = self.panel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if self.model.kind == nil { panel?.orderOut(nil) }
        }
    }

    private static func putOnClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func show(_ kind: VoiceToastModel.Kind, for seconds: TimeInterval?, after delay: TimeInterval = 0) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            let panel = self.panel ?? self.makePanel()
            self.panel = panel
            if !panel.isVisible { self.position(panel); panel.orderFrontRegardless() }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.model.kind = kind }
            guard let seconds else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.hideTask = nil
            if kind == .missedPaste { self.pending = nil }
            self.close()
        }
    }

    /// Where the pill sits: bottom centre of the screen you're on, just above the Dock.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(Self.frame(in: screen.visibleFrame, lifted: pillUp), display: false)
    }

    /// The note's panel: on the pill's spot, or `lift` above it while the pill is up.
    static func frame(in v: NSRect, lifted: Bool) -> NSRect {
        NSRect(x: v.midX - panelSize.width / 2,
               y: v.minY + RecordingHUDPresenter.pillInset - 12 + (lifted ? lift : 0),
               width: panelSize.width, height: panelSize.height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: VoiceToastView(model: model, presenter: self))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }
}

// MARK: - View

/// An ink capsule like the pill, white type, small buttons. Outside the capsule the panel is
/// fully clear, so clicks there go to whatever is underneath.
struct VoiceToastView: View {
    @ObservedObject var model: VoiceToastModel
    let presenter: VoiceToastPresenter

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let kind = model.kind {
                VoiceToastCapsule(kind: kind, presenter: presenter)
                    .id(kind)
                    .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity),
                                            removal: .opacity))
                    .padding(.bottom, 12)
            }
        }
        .frame(width: VoiceToastPresenter.panelSize.width, height: VoiceToastPresenter.panelSize.height)
    }
}

struct VoiceToastCapsule: View {
    let kind: VoiceToastModel.Kind
    let presenter: VoiceToastPresenter

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            buttons
        }
        .padding(.leading, 14)
        .padding(.trailing, hasButtons ? 6 : 16)
        .frame(height: 34)
        .background(Capsule(style: .continuous).fill(Brand.ink.opacity(0.96)))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var message: String {
        switch kind {
        case .learned(let words): return "Learned " + words.map { "“\($0)”" }.joined(separator: ", ")
        case .missedPaste: return "Didn't paste"
        case .pasting: return "Pasting…"
        case .pasted: return "Pasted"
        case .copied: return "Copied"
        case .stillMissed: return "Copied instead. Press ⌘V"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .pasting:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
        default:
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
        }
    }

    private var symbol: String {
        switch kind {
        case .learned: "character.book.closed"
        case .missedPaste, .stillMissed: "exclamationmark.circle"
        case .pasting: ""
        case .pasted: "checkmark"
        case .copied: "doc.on.clipboard"
        }
    }

    private var tint: Color {
        switch kind {
        case .pasted: Brand.led
        case .learned: Brand.blueOnDark
        default: .white.opacity(0.7)
        }
    }

    private var hasButtons: Bool {
        switch kind {
        case .learned, .missedPaste: true
        default: false
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch kind {
        case .learned:
            ToastButton(title: "Undo") { presenter.undoLearned() }
        case .missedPaste:
            HStack(spacing: 4) {
                ToastButton(title: "Paste", primary: true) { presenter.paste() }
                ToastButton(title: "Copy") { presenter.copy() }
                ToastButton(symbol: "xmark") { presenter.close() }
            }
        default:
            EmptyView()
        }
    }
}

private struct ToastButton: View {
    var title: String?
    var symbol: String?
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    init(title: String, primary: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.primary = primary; self.action = action
    }

    init(symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let title { Text(title).font(.system(size: 12, weight: .semibold)) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            }
            .foregroundStyle(primary ? Brand.ink : .white.opacity(0.9))
            .padding(.horizontal, title == nil ? 0 : 11)
            .frame(width: title == nil ? 22 : nil, height: 22)
            .background(Capsule(style: .continuous)
                .fill(primary ? Color.white.opacity(hovering ? 1 : 0.92) : Color.white.opacity(hovering ? 0.2 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
