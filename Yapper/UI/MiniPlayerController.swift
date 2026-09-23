import AppKit
import SwiftUI
import Combine

/// Hosts the mini player inside a floating NSPanel. Subscribes to AppState for the current
/// ReadingItem; when one appears, slides the panel in from the bottom-right of the screen.
/// When playback finishes, auto-dismisses after a short delay.
@MainActor
final class MiniPlayerController: NSObject {
    private weak var state: AppState?
    private var panel: NSPanel?
    /// Liner notes, child-windowed to the player so it travels with the deck.
    private var transcriptPanel: NSPanel?
    private var hostingView: NSView?
    private var cancellables = Set<AnyCancellable>()
    private var stateCancellable: AnyCancellable?    // replaced each show() — never accumulates
    private var dismissTask: Task<Void, Never>?
    private let delegateShim = PanelDelegateShim()

    private static let minimalSize = MiniPlayerView.panelSize   // card + shadow margin
    private static let edgeMargin: CGFloat = 16
    private static let slideDuration: TimeInterval = 0.2
    private static let dismissDelay: TimeInterval = 3.0

    /// Where the visible body sits inside the panel: the minimal card floats in a transparent
    /// shadow margin, the cassette deck fills its panel. Corner placement, edge clamping, the
    /// saved position and the liner notes all measure the body, so the margin never shifts the
    /// card on screen.
    private var bodyInsets: NSEdgeInsets {
        guard (state?.settings.miniPlayerTheme ?? .minimal) == .minimal else { return NSEdgeInsetsZero }
        let m = MiniPlayerView.shadowMargin
        return NSEdgeInsets(top: m.top, left: m.leading, bottom: m.bottom, right: m.trailing)
    }

    private var bodySize: NSSize {
        let i = bodyInsets
        return NSSize(width: panelSize.width - i.left - i.right, height: panelSize.height - i.top - i.bottom)
    }

    /// Panel size depends on the chosen theme (and, for the cassette, the user's size setting).
    private var panelSize: NSSize {
        switch state?.settings.miniPlayerTheme ?? .minimal {
        case .minimal:
            return Self.minimalSize
        case .cassette:
            let scale = CGFloat(state?.settings.cassetteScale ?? 1.0)
            let w = CassetteDeckView.baseWidth * scale
            return NSSize(width: w, height: w / CassetteDeckView.aspect)
        }
    }

    init(state: AppState) {
        self.state = state
        super.init()
        delegateShim.onMoved = { [weak self] origin in
            self?.persistOrigin(origin)
        }
        observeReading()
    }

    private func observeReading() {
        guard let state else { return }
        state.$currentReading
            .removeDuplicates()
            .sink { [weak self] reading in
                Task { @MainActor in
                    if let reading {
                        self?.show(for: reading)
                    } else {
                        self?.dismiss(animated: true)
                    }
                }
            }
            .store(in: &cancellables)

        // Liner notes open/close from the deck's TRANSCRIPT marking, its counter, or the notes'
        // own close button — all of them just flip this flag.
        state.$transcriptVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                Task { @MainActor in
                    if visible { self?.showTranscript() } else { self?.hideTranscript() }
                }
            }
            .store(in: &cancellables)

        // If the player is on screen and the user switches theme, rebuild it live.
        state.settings.$miniPlayerTheme
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.panel != nil else { return }
                self.hideTranscript()          // child of the panel we're about to throw away
                self.panel?.orderOut(nil)
                self.panel = nil
                if let r = self.state?.currentReading,
                   let active = self.state?.tts.active,
                   case .streaming = active {
                    self.show(for: r)
                }
            }
            .store(in: &cancellables)

        // Live-resize the visible deck when the cassette scale changes (Settings slider or pinch).
        // The payload carries the NEW value — the property itself hasn't been written yet here.
        state.settings.$cassetteScale
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newScale in
                guard let self, let panel = self.panel, panel.isVisible,
                      self.state?.settings.miniPlayerTheme == .cassette else { return }
                let w = CassetteDeckView.baseWidth * CGFloat(newScale)
                let size = NSSize(width: w, height: w / CassetteDeckView.aspect)
                // Grow/shrink around the deck's center, then clamp fully on-screen.
                var frame = NSRect(x: panel.frame.midX - size.width / 2,
                                   y: panel.frame.midY - size.height / 2,
                                   width: size.width, height: size.height)
                if let screen = panel.screen ?? NSScreen.main {
                    let v = screen.visibleFrame
                    frame.origin.x = min(max(frame.origin.x, v.minX), max(v.maxX - frame.width, v.minX))
                    frame.origin.y = min(max(frame.origin.y, v.minY), max(v.maxY - frame.height, v.minY))
                }
                panel.setFrame(frame, display: true)
            }
            .store(in: &cancellables)
    }

    private func show(for reading: ReadingItem) {
        guard let state else { return }
        guard case .streaming(let streamer) = state.tts.active else {
            // Native fallback path: no mini player for v1 (no scrubber data).
            return
        }
        dismissTask?.cancel()

        let onPlayPause: () -> Void = { [weak state] in state?.tts.pauseOrResume() }
        let onClose: () -> Void = { [weak self, weak state] in
            state?.tts.stop()
            self?.dismiss(animated: true)
            state?.currentReading = nil
        }
        let onSeek: (TimeInterval) -> Void = { [weak state] seconds in
            if case .streaming(let s)? = state?.tts.active { s.seek(to: seconds) }
        }
        let onCycleSpeed: () -> Void = { [weak state] in
            guard let state, case .streaming(let s) = state.tts.active else { return }
            s.cycleRate()
            state.settings.playbackRate = Double(s.rate)   // persist for the next read
        }
        // Deck REW/FF: jump the timeline (seek clamps to 0…duration internally).
        let skip: (TimeInterval) -> Void = { [weak state] delta in
            guard let state, case .streaming(let s) = state.tts.active else { return }
            s.seek(to: s.currentTime + delta)
        }
        // Pinch on the deck body: accumulate the magnification into the persisted scale;
        // the $cassetteScale sink above resizes the panel live.
        let onMagnify: (CGFloat) -> Void = { [weak state] delta in
            guard let state else { return }
            let range = SettingsStore.cassetteScaleRange
            let scaled = state.settings.cassetteScale * (1 + Double(delta))
            state.settings.cassetteScale = min(max(scaled, range.lowerBound), range.upperBound)
        }
        // Edge/corner drag finished: fold the final width back into the persisted scale so the
        // Settings slider, the pinch gesture, and the next launch all agree with the screen.
        // The deck's drag surface already resized the panel live; this write is a no-op frame-wise.
        let onResizeEnd: (CGFloat) -> Void = { [weak state] finalWidth in
            guard let state else { return }
            let range = SettingsStore.cassetteScaleRange
            let scale = Double(finalWidth / CassetteDeckView.baseWidth)
            state.settings.cassetteScale = min(max(scale, range.lowerBound), range.upperBound)
        }

        let content: AnyView
        switch state.settings.miniPlayerTheme {
        case .cassette:
            content = AnyView(CassettePlayerHost(
                streamer: streamer, coordinator: state.tts, appState: state, reading: reading,
                onPlayPause: onPlayPause, onStop: onClose,
                onSkipBack: { skip(-10) }, onSkipForward: { skip(10) },
                onCycleSpeed: onCycleSpeed, onSeek: onSeek,
                onMagnify: onMagnify, onResizeEnd: onResizeEnd))
        case .minimal:
            content = AnyView(MiniPlayerView(
                streamer: streamer, coordinator: state.tts, appState: state, reading: reading,
                onPlayPause: onPlayPause, onClose: onClose, onSeek: onSeek, onCycleSpeed: onCycleSpeed))
        }

        // Observe terminal states to auto-dismiss after a beat. Kept in a dedicated cancellable so
        // it's replaced (not stacked) every time show() runs.
        stateCancellable = streamer.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                guard let self else { return }
                switch s {
                case .finished, .failed, .idle:
                    self.scheduleAutoDismiss()
                default:
                    self.dismissTask?.cancel()
                }
            }

        // If the theme (and therefore size) changed since the panel was built, rebuild it.
        // Tolerant compare: an edge-drag resize round-trips through cassetteScale and can land
        // a hair off the recomputed size — that must not count as a size change.
        if let p = panel, abs(p.frame.width - panelSize.width) > 0.5 || abs(p.frame.height - panelSize.height) > 0.5 {
            p.orderOut(nil)
            panel = nil
        }
        ensurePanel(with: content)
        slideIn()
        // Notes left open when the next queued item starts: rebuild them against the new player
        // rather than leaving a panel bound to the finished one.
        if state.transcriptVisible { showTranscript() }
    }

    // MARK: - Liner notes

    /// Builds the notes fresh each time it opens: the panel is bound to one `SentenceStreamPlayer`,
    /// and a new read means a new player. Attached as a child window so dragging the deck drags
    /// the notes with it, and closing the deck closes them.
    private func showTranscript() {
        guard let state, let parent = panel, parent.isVisible,
              case .streaming(let streamer) = state.tts.active else { return }

        let content = AnyView(TranscriptView(
            streamer: streamer,
            sourceApp: state.currentReading?.sourceApp ?? "Yapper",
            onSeek: { [weak state] seconds in
                if case .streaming(let s)? = state?.tts.active { s.seek(to: seconds) }
            },
            onClose: { [weak state] in state?.transcriptVisible = false }))

        hideTranscript()

        let size = transcriptSize(for: parent)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                  // SwiftUI .shadow provides it
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hosting = FirstMouseHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        p.setFrameOrigin(transcriptOrigin(for: parent, size: size))
        parent.addChildWindow(p, ordered: .above)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        transcriptPanel = p
    }

    private func hideTranscript() {
        guard let p = transcriptPanel else { return }
        transcriptPanel = nil
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    /// The visible body of the player on screen. The notes line up with this, not the panel edge.
    private func playerBody(of parent: NSPanel) -> NSRect {
        let i = bodyInsets
        return NSRect(x: parent.frame.minX + i.left, y: parent.frame.minY + i.bottom,
                      width: parent.frame.width - i.left - i.right,
                      height: parent.frame.height - i.top - i.bottom)
    }

    private func transcriptSize(for parent: NSPanel) -> NSSize {
        // Track the deck's width so the pair reads as one object, within sane reading limits.
        let w = min(max(playerBody(of: parent).width, 300), 520)
        let screenH = (parent.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return NSSize(width: w, height: min(380, max(220, screenH * 0.4)))
    }

    /// Sits above the player, left-aligned with it; flips below when there's no headroom, and is
    /// clamped on-screen either way.
    private func transcriptOrigin(for parent: NSPanel, size: NSSize) -> NSPoint {
        let gap: CGFloat = 8
        let body = playerBody(of: parent)
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var y = body.maxY + gap
        if y + size.height > visible.maxY {
            y = body.minY - gap - size.height
        }
        y = min(max(y, visible.minY), max(visible.maxY - size.height, visible.minY))
        let x = min(max(body.minX, visible.minX), max(visible.maxX - size.width, visible.minX))
        return NSPoint(x: x, y: y)
    }

    private func ensurePanel(with content: AnyView) {
        if let panel {
            applyResizeBehavior(panel)
            let hosting = FirstMouseHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: panelSize)
            hosting.autoresizingMask = [.width, .height]   // track live panel resizes
            panel.contentView = hosting
            hostingView = hosting
            return
        }

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                 // SwiftUI .shadow provides it
        p.level = .floating
        p.hidesOnDeactivate = false
        // Slice 7 will add a dedicated drag handle so the slider gesture isn't stolen by window-drag.
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        applyResizeBehavior(p)

        let hosting = FirstMouseHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]   // track live panel resizes
        p.contentView = hosting

        p.delegate = delegateShim
        self.panel = p
        self.hostingView = hosting
    }

    /// Publishes the deck's resize constraints on the panel. The deck's drag surface implements
    /// the edge/corner tracking itself (AppKit's automatic borderless resizing only engages on
    /// the right-hand edges) and reads these limits and the aspect back at drag time. The
    /// minimal theme keeps its fixed size — no constraints, no resize bands.
    private func applyResizeBehavior(_ p: NSPanel) {
        guard state?.settings.miniPlayerTheme == .cassette else { return }
        p.aspectRatio = NSSize(width: CassetteDeckView.aspect, height: 1)
        let range = SettingsStore.cassetteScaleRange
        let minW = CassetteDeckView.baseWidth * range.lowerBound
        let maxW = CassetteDeckView.baseWidth * range.upperBound
        p.minSize = NSSize(width: minW, height: minW / CassetteDeckView.aspect)
        p.maxSize = NSSize(width: maxW, height: maxW / CassetteDeckView.aspect)
    }

    private func slideIn() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let cornerOrigin = corner(in: visible, for: state?.settings.miniPlayerDefaultCorner ?? .bottomRight)
        // Honor the user's dragged position only if it still fits fully on the current screen;
        // otherwise (stale value, display/resolution change) reset to the corner default. Clamp at
        // the end as a final guarantee the body is never parked below or beyond the visible frame.
        // All of that is in body coordinates; the panel then sits around the body.
        let saved = persistedOrigin()
        let preferred = (saved.map { isFullyVisible($0, in: visible) } == true) ? saved! : cornerOrigin
        let bodyOrigin = clampToVisible(preferred, in: visible)
        let finalOrigin = NSPoint(x: bodyOrigin.x - bodyInsets.left, y: bodyOrigin.y - bodyInsets.bottom)
        let startOrigin = NSPoint(x: finalOrigin.x, y: finalOrigin.y - 30)

        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // setFrame, not setFrameOrigin: the animator proxy silently drops setFrameOrigin, which
            // left the panel at the start point — and saved that as the position, 30pt lower each read.
            panel.animator().setFrame(NSRect(origin: finalOrigin, size: panel.frame.size), display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.dismissDelay))
            if Task.isCancelled { return }
            self?.dismiss(animated: true)
            self?.state?.currentReading = nil
        }
    }

    /// True when a body placed at `origin` sits entirely within the visible frame.
    private func isFullyVisible(_ origin: NSPoint, in visible: NSRect) -> Bool {
        origin.x >= visible.minX &&
        origin.y >= visible.minY &&
        origin.x + bodySize.width <= visible.maxX &&
        origin.y + bodySize.height <= visible.maxY
    }

    /// Keeps the body fully inside `visible` — never below the bottom edge, never past a side.
    /// (Its transparent shadow margin may overhang; there's nothing there to lose.)
    private func clampToVisible(_ origin: NSPoint, in visible: NSRect) -> NSPoint {
        let maxX = visible.maxX - bodySize.width
        let maxY = visible.maxY - bodySize.height
        // If the screen is somehow smaller than the panel, minX/minY still wins (top-left aligned).
        let x = min(max(origin.x, visible.minX), max(maxX, visible.minX))
        let y = min(max(origin.y, visible.minY), max(maxY, visible.minY))
        return NSPoint(x: x, y: y)
    }

    /// Body origin for the default corner.
    private func corner(in rect: NSRect, for corner: MiniPlayerCorner) -> NSPoint {
        let m = Self.edgeMargin
        let size = bodySize
        switch corner {
        case .bottomRight: return NSPoint(x: rect.maxX - size.width - m, y: rect.minY + m)
        case .bottomLeft:  return NSPoint(x: rect.minX + m,              y: rect.minY + m)
        case .topRight:    return NSPoint(x: rect.maxX - size.width - m, y: rect.maxY - size.height - m)
        case .topLeft:     return NSPoint(x: rect.minX + m,              y: rect.maxY - size.height - m)
        }
    }

    // MARK: - Position persistence

    /// Saves where the body sits, not the panel, so the card lands in the same spot whatever
    /// shadow margin surrounds it.
    private func persistOrigin(_ panelOrigin: NSPoint) {
        guard let settings = state?.settings else { return }
        let origin = NSPoint(x: panelOrigin.x + bodyInsets.left, y: panelOrigin.y + bodyInsets.bottom)
        UserDefaults.standard.set(Double(origin.x), forKey: SettingsStore.Key.miniPlayerCornerX.rawValue)
        UserDefaults.standard.set(Double(origin.y), forKey: SettingsStore.Key.miniPlayerCornerY.rawValue)
        _ = settings // silence "unused" warning while we don't need to call into the store
    }

    private func persistedOrigin() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: SettingsStore.Key.miniPlayerCornerX.rawValue) != nil,
              d.object(forKey: SettingsStore.Key.miniPlayerCornerY.rawValue) != nil
        else { return nil }
        let x = d.double(forKey: SettingsStore.Key.miniPlayerCornerX.rawValue)
        let y = d.double(forKey: SettingsStore.Key.miniPlayerCornerY.rawValue)
        return NSPoint(x: x, y: y)
    }

    private func dismiss(animated: Bool) {
        // The notes belong to the read that's going away — never outlive the deck.
        state?.transcriptVisible = false
        hideTranscript()
        guard let panel else { return }
        if !animated {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }
}

/// NSHostingView that accepts the first click even while the app is inactive. Yapper is a
/// background accessory app, so EVERY click on the floating player is a "first mouse" — the
/// default hosting view treats that click as focus-only and SwiftUI buttons/gestures never fire.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Lightweight NSWindowDelegate that just forwards the post-move origin to the controller.
private final class PanelDelegateShim: NSObject, NSWindowDelegate {
    var onMoved: ((NSPoint) -> Void)?
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onMoved?(window.frame.origin)
    }
}
