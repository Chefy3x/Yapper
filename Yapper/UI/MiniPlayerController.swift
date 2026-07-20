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
    private var hostingView: NSView?
    private var cancellables = Set<AnyCancellable>()
    private var stateCancellable: AnyCancellable?    // replaced each show() — never accumulates
    private var dismissTask: Task<Void, Never>?
    private let delegateShim = PanelDelegateShim()

    private static let minimalSize = NSSize(width: 336, height: 96)
    private static let edgeMargin: CGFloat = 16
    private static let slideDuration: TimeInterval = 0.2
    private static let dismissDelay: TimeInterval = 3.0

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

        // If the player is on screen and the user switches theme, rebuild it live.
        state.settings.$miniPlayerTheme
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.panel != nil else { return }
                self.panel?.orderOut(nil)
                self.panel = nil
                if let r = self.state?.currentReading,
                   let active = self.state?.tts.active,
                   case .elevenLabs = active {
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
        guard case .elevenLabs(let streamer) = state.tts.active else {
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
            if case .elevenLabs(let s)? = state?.tts.active { s.seek(to: seconds) }
        }
        let onCycleSpeed: () -> Void = { [weak state] in
            guard let state, case .elevenLabs(let s) = state.tts.active else { return }
            s.cycleRate()
            state.settings.playbackRate = Double(s.rate)   // persist for the next read
        }
        // Deck REW/FF: jump the timeline (seek clamps to 0…duration internally).
        let skip: (TimeInterval) -> Void = { [weak state] delta in
            guard let state, case .elevenLabs(let s) = state.tts.active else { return }
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
                streamer: streamer, coordinator: state.tts, reading: reading,
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
        // the end as a final guarantee the panel is never parked below or beyond the visible frame.
        let saved = persistedOrigin()
        let preferred = (saved.map { isFullyVisible($0, in: visible) } == true) ? saved! : cornerOrigin
        let finalOrigin = clampToVisible(preferred, in: visible)
        let startOrigin = NSPoint(x: finalOrigin.x, y: finalOrigin.y - 30)

        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(finalOrigin)
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

    /// True when a panel placed at `origin` sits entirely within the visible frame.
    private func isFullyVisible(_ origin: NSPoint, in visible: NSRect) -> Bool {
        origin.x >= visible.minX &&
        origin.y >= visible.minY &&
        origin.x + panelSize.width <= visible.maxX &&
        origin.y + panelSize.height <= visible.maxY
    }

    /// Keeps the panel fully inside `visible` — never below the bottom edge, never past a side.
    private func clampToVisible(_ origin: NSPoint, in visible: NSRect) -> NSPoint {
        let maxX = visible.maxX - panelSize.width
        let maxY = visible.maxY - panelSize.height
        // If the screen is somehow smaller than the panel, minX/minY still wins (top-left aligned).
        let x = min(max(origin.x, visible.minX), max(maxX, visible.minX))
        let y = min(max(origin.y, visible.minY), max(maxY, visible.minY))
        return NSPoint(x: x, y: y)
    }

    private func corner(in rect: NSRect, for corner: MiniPlayerCorner) -> NSPoint {
        let m = Self.edgeMargin
        switch corner {
        case .bottomRight: return NSPoint(x: rect.maxX - panelSize.width - m, y: rect.minY + m)
        case .bottomLeft:  return NSPoint(x: rect.minX + m,                   y: rect.minY + m)
        case .topRight:    return NSPoint(x: rect.maxX - panelSize.width - m, y: rect.maxY - panelSize.height - m)
        case .topLeft:     return NSPoint(x: rect.minX + m,                   y: rect.maxY - panelSize.height - m)
        }
    }

    // MARK: - Position persistence

    private func persistOrigin(_ origin: NSPoint) {
        guard let settings = state?.settings else { return }
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
