import SwiftUI
import AppKit

/// Full-face window-drag surface with cutouts. AppKit-level `hitTest` returns nil inside the
/// passthrough rects, so SwiftUI controls layered around it are guaranteed to receive their
/// clicks — no reliance on SwiftUI/NSView hit-test ordering.
/// Whole-body window drag via AppKit. SwiftUI DragGesture is a dead end in this borderless,
/// non-activating panel (gestures never engage without key-window status — verified empirically),
/// while NSView.mouseDown + performDrag works. hitTest returns nil inside the control zones so
/// the transport Buttons, speed pill, and top-left chips receive their clicks.
private struct DeckDragSurface: NSViewRepresentable {
    let passthrough: [CGRect]   // unit-square rects (fractions of the deck face)
    var onMagnify: ((CGFloat) -> Void)?
    var onResizeEnd: ((CGFloat) -> Void)?
    /// Scrub support: presses inside `scrubZone` (unit rect) report a 0…1 fraction measured
    /// along `rulerSpan` (unit x-range) instead of dragging the window. AppKit-level because
    /// SwiftUI DragGesture never engages in this non-activating panel.
    var scrubZone: CGRect? = nil
    var rulerSpan: ClosedRange<CGFloat>? = nil
    var onScrubChanged: ((CGFloat) -> Void)? = nil
    var onScrubEnded: ((CGFloat) -> Void)? = nil
    /// Pointer enters/leaves the deck face — drives reveal-on-hover chrome.
    var onHoverChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        apply(to: v)
        return v
    }
    func updateNSView(_ nsView: DragView, context: Context) {
        apply(to: nsView)
    }
    private func apply(to v: DragView) {
        v.passthrough = passthrough
        v.onMagnify = onMagnify
        v.onResizeEnd = onResizeEnd
        v.scrubZone = scrubZone
        v.rulerSpan = rulerSpan
        v.onScrubChanged = onScrubChanged
        v.onScrubEnded = onScrubEnded
        v.onHoverChanged = onHoverChanged
    }

    final class DragView: NSView {
        var passthrough: [CGRect] = []
        var onMagnify: ((CGFloat) -> Void)?
        var onResizeEnd: ((CGFloat) -> Void)?
        var scrubZone: CGRect? = nil
        var rulerSpan: ClosedRange<CGFloat>? = nil
        var onScrubChanged: ((CGFloat) -> Void)? = nil
        var onScrubEnded: ((CGFloat) -> Void)? = nil
        var onHoverChanged: ((Bool) -> Void)? = nil
        private var scrubFraction: CGFloat? = nil   // non-nil while a scrub drag is live

        /// Grab bands for window-style resizing: 10pt along each edge, with generous 26pt
        /// corner squares — a too-small corner square makes near-corner grabs resolve as an
        /// edge band, which anchors the opposite side and reads as "the wrong side moved".
        private static let edgeBand: CGFloat = 10
        private static let cornerBand: CGFloat = 26
        private var cursorTracking: NSTrackingArea?

        override var isFlipped: Bool { true }   // unit rects use SwiftUI's top-left origin
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func magnify(with event: NSEvent) {
            onMagnify?(event.magnification)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let p = convert(point, from: superview)
            guard bounds.width > 0, bounds.height > 0, bounds.contains(p) else { return nil }
            if resizeEdge(at: p) != nil { return self }   // resize bands beat the control cutouts
            let unit = CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
            for rect in passthrough where rect.contains(unit) { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if let edge = resizeEdge(at: p) {
                trackResize(edge)
            } else if isInScrubZone(p) {
                reportScrub(event)          // press = the needle jumps to the pointer
            } else {
                window?.performDrag(with: event)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if scrubFraction != nil { reportScrub(event) }
        }

        override func mouseUp(with event: NSEvent) {
            if let f = scrubFraction {
                scrubFraction = nil
                onScrubEnded?(f)
            }
        }

        private func isInScrubZone(_ p: NSPoint) -> Bool {
            guard let zone = scrubZone, bounds.width > 0, bounds.height > 0 else { return false }
            return zone.contains(CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
        }

        /// Absolute media-player mapping: the fraction is the pointer's position along the
        /// ruler span, clamped at the ends. Drags keep reporting even once the pointer
        /// leaves the zone — AppKit keeps routing them here until mouse-up.
        private func reportScrub(_ event: NSEvent) {
            guard let span = rulerSpan, span.upperBound > span.lowerBound, bounds.width > 0
            else { return }
            let unitX = convert(event.locationInWindow, from: nil).x / bounds.width
            let f = min(max((unitX - span.lowerBound) / (span.upperBound - span.lowerBound), 0), 1)
            scrubFraction = f
            onScrubChanged?(f)
        }

        // MARK: Window-style edge/corner resizing

        /// The deck does its own resize tracking: AppKit's automatic resizing for borderless
        /// windows only engages on the right-hand/bottom edges (grow-box lineage), so the left
        /// side never worked. Manual tracking makes all edges and corners behave identically.
        private enum Edge {
            case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
            var pullsLeft: Bool   { self == .left   || self == .topLeft    || self == .bottomLeft }
            var pullsRight: Bool  { self == .right  || self == .topRight   || self == .bottomRight }
            var pullsTop: Bool    { self == .top    || self == .topLeft    || self == .topRight }
            var pullsBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
        }

        /// Band lookup in flipped view coordinates (y = 0 is the visual top).
        private func resizeEdge(at p: NSPoint) -> Edge? {
            let w = bounds.width, h = bounds.height
            let e = Self.edgeBand, c = Self.cornerBand
            if p.x <= c && p.y <= c { return .topLeft }
            if p.x >= w - c && p.y <= c { return .topRight }
            if p.x <= c && p.y >= h - c { return .bottomLeft }
            if p.x >= w - c && p.y >= h - c { return .bottomRight }
            if p.x <= e { return .left }
            if p.x >= w - e { return .right }
            if p.y <= e { return .top }
            if p.y >= h - e { return .bottom }
            return nil
        }

        /// Synchronous tracking loop — the same ownership model performDrag uses for moves.
        /// The aspect is locked, so every drag reduces to a width change anchored at the
        /// opposite edge/corner; pure side drags keep the bottom edge fixed (the deck usually
        /// sits near the bottom of the screen). Frame math runs in screen coordinates (y up).
        ///
        /// Smoothness: drag events arrive faster than the deck can redraw, so the loop
        /// coalesces the queue down to the freshest pointer position and marks the frame
        /// dirty with `display: false` — Core Animation then redraws on its refresh-rate
        /// commits (the deferred pipeline native live-resize uses) instead of the window
        /// being forced through a full synchronous redraw per mouse event.
        private func trackResize(_ edge: Edge) {
            guard let window else { return }
            let start = window.frame
            let startMouse = NSEvent.mouseLocation
            let ratio = window.aspectRatio
            let aspect = (ratio.width > 0 && ratio.height > 0)
                ? ratio.width / ratio.height
                : start.width / max(start.height, 1)
            let minW = max(window.minSize.width, 100)
            let maxW = min(window.maxSize.width, 20_000)
            let anchor = NSPoint(x: edge.pullsLeft ? start.maxX : start.minX,
                                 y: edge.pullsBottom ? start.maxY : start.minY)
            var appliedW = start.width

            while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
                  event.type != .leftMouseUp {
                // Skim off drags already queued behind this one — only the freshest pointer
                // matters. (A queued mouse-up is never skipped: no drag can follow it, so the
                // outer nextEvent call picks it up on the next pass.)
                while window.nextEvent(matching: .leftMouseDragged, until: .distantPast,
                                       inMode: .eventTracking, dequeue: true) != nil {}
                let m = NSEvent.mouseLocation
                // Candidate widths from each edge being pulled; on corners the axis the
                // mouse has moved farthest along wins, so diagonals feel natural.
                var widths: [CGFloat] = []
                if edge.pullsLeft   { widths.append(start.width - (m.x - startMouse.x)) }
                if edge.pullsRight  { widths.append(start.width + (m.x - startMouse.x)) }
                if edge.pullsTop    { widths.append((start.height + (m.y - startMouse.y)) * aspect) }
                if edge.pullsBottom { widths.append((start.height - (m.y - startMouse.y)) * aspect) }
                guard let dominant = widths.max(by: { abs($0 - start.width) < abs($1 - start.width) })
                else { continue }
                let newW = min(max(dominant, minW), maxW)
                if abs(newW - appliedW) < 0.25 { continue }   // sub-quarter-point jitter
                appliedW = newW
                let newH = newW / aspect
                // The dragged edge follows the pointer and its opposite pins. Pure top/bottom
                // drags have no horizontal pointer intent, so the aspect-locked width growth
                // splits evenly about the center — pinning one side reads as the wrong side
                // moving when a near-corner grab resolves as an edge.
                let x = edge.pullsLeft  ? anchor.x - newW
                      : edge.pullsRight ? anchor.x
                      : start.midX - newW / 2
                window.setFrame(NSRect(x: x,
                                       y: edge.pullsBottom ? anchor.y - newH : anchor.y,
                                       width: newW, height: newH),
                                display: false)
            }
            window.displayIfNeeded()   // land the final size with a committed, crisp draw
            onResizeEnd?(window.frame.width)
        }

        // MARK: Resize cursors

        /// Cursor rects only work in key windows and this panel never becomes key, so cursor
        /// feedback runs off an always-active tracking area instead.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTracking { removeTrackingArea(cursorTracking) }
            let t = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(t)
            cursorTracking = t
        }

        override func cursorUpdate(with event: NSEvent) { refreshCursor() }
        override func mouseMoved(with event: NSEvent) { refreshCursor() }
        override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
            onHoverChanged?(false)
        }

        private func refreshCursor() {
            guard let window else { return }
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard let edge = resizeEdge(at: p) else {
                NSCursor.arrow.set()
                return
            }
            if #available(macOS 15, *) {
                let position: NSCursor.FrameResizePosition
                switch edge {
                case .left:        position = .left
                case .right:       position = .right
                case .top:         position = .top
                case .bottom:      position = .bottom
                case .topLeft:     position = .topLeft
                case .topRight:    position = .topRight
                case .bottomLeft:  position = .bottomLeft
                case .bottomRight: position = .bottomRight
                }
                NSCursor.frameResize(position: position, directions: .all).set()
            } else {
                // Pre-macOS 15 has no directional frame-resize cursor; use the
                // legacy axis cursors (corners fall back to the arrow).
                switch edge {
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .top, .bottom: NSCursor.resizeUpDown.set()
                default:            NSCursor.arrow.set()
                }
            }
        }
    }
}

/// Loads the cassette deck artwork once from the app bundle.
/// The deck body and the two reel sprites are separate user-made cutouts from one registered
/// canvas: the body's alpha defines the window silhouette, and each sprite is hub-centered so
/// it rotates in place with zero wobble.
enum CassetteAsset {
    static let deck: NSImage? = load("cassette-deck")
    static let reelLeft: NSImage? = load("cassette-reel-left")
    static let reelRight: NSImage? = load("cassette-reel-right")
    /// Individual transport caps, registered to the body — [REW, PLAY, STOP, FF, REC].
    static let caps: [NSImage?] = ["rew", "play", "stop", "ff", "rec"].map { load("cassette-cap-\($0)") }

    private static func load(_ name: String) -> NSImage? {
        if let img = NSImage(named: name) { return img }
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

/// Photoreal cassette player: the cut-out deck PNG IS the body (its alpha is the silhouette),
/// with real reel sprites rotating in place while playing, the PLAY button rendered "pressed"
/// during playback, and invisible click targets over the transport buttons.
/// REC latches down while Conversation Mode is on — the deck is recording the conversation.
///
/// All coordinates are fractions of the view, measured against the body cutout's alpha bbox
/// (1064×656, aspect ≈ 1.622); buttons were located by luminance-profiling the gap shadows.
struct CassetteDeckView: View {
    var isPlaying: Bool = false
    var isBuffering: Bool = false
    var isRecording: Bool = false        // Conversation Mode → REC cap latches down
    var rate: Double = 1.0               // playback speed multiplier → spin speed
    var speedLabel: String = "1×"
    var currentTime: TimeInterval = 0    // drives the tape-position groove + counters
    var totalDuration: TimeInterval = 0
    /// Stretches of the timeline whose audio already exists (seek lands instantly inside them).
    var bufferedRanges: [ClosedRange<TimeInterval>] = []
    /// There is text to read along with — hides the transcript affordances when there isn't.
    var hasTranscript: Bool = false
    var isTranscriptOpen: Bool = false

    var onPlayPause: () -> Void = {}
    var onStop: () -> Void = {}
    /// REW/FF work the timeline like a real deck — a click jumps back/forward 10 seconds.
    /// (Playback speed lives on the pill.)
    var onSkipBack: () -> Void = {}
    var onSkipForward: () -> Void = {}
    var onCycleSpeed: () -> Void = {}
    var onToggleRecord: () -> Void = {}
    /// Scrub on the tape-position groove — reports the absolute target time.
    var onSeek: (TimeInterval) -> Void = { _ in }
    /// Show/hide the liner notes (the transcript panel).
    var onToggleTranscript: () -> Void = {}
    /// Trackpad pinch on the deck body — reports each magnification delta for resizing.
    var onMagnify: ((CGFloat) -> Void)? = nil
    /// A window-style edge/corner drag finished — reports the final deck width for persistence.
    var onResizeEnd: ((CGFloat) -> Void)? = nil

    static let aspect: CGFloat = 1064.0 / 656.0
    /// Design width at scale 1.0; the panel decides the actual size (baseWidth × cassetteScale).
    static let baseWidth: CGFloat = 446

    // Reel sprite registration, measured from the cutouts' alpha channels (both layers share
    // one canvas, so these are exact — not estimated).
    private static let leftReel  = CGPoint(x: 0.3515, y: 0.4756)
    private static let rightReel = CGPoint(x: 0.6692, y: 0.4733)
    private static let leftReelDia: CGFloat  = 0.0940   // sprite side as a fraction of width
    private static let rightReelDia: CGFloat = 0.0968
    // Click-target row (hotspots only; the pressed VISUAL is the registered cap sprites below).
    // Cap slots sit on an exactly even 0.1008 pitch (measured from the gap shadows).
    private static let btnY: CGFloat = 0.884
    private static let btnXs: [CGFloat] = [0.309, 0.410, 0.510, 0.611, 0.713]   // REW PLAY STOP FF REC
    private static let btnWs: [CGFloat] = [0.085, 0.085, 0.085, 0.085, 0.085]
    private static let btnH: CGFloat = 0.080

    /// Cap sprite registration, measured from the caps cutout's alpha (same canvas as the body).
    private struct CapSprite {
        let center: CGPoint   // fractions of the deck face
        let size: CGSize      // fractions of face width/height
    }
    private static let capSprites: [CapSprite] = [
        CapSprite(center: CGPoint(x: 0.3102, y: 0.9078), size: CGSize(width: 0.0996, height: 0.1326)),   // rew
        CapSprite(center: CGPoint(x: 0.4074, y: 0.9108), size: CGSize(width: 0.1043, height: 0.1357)),   // play
        CapSprite(center: CGPoint(x: 0.5080, y: 0.9093), size: CGSize(width: 0.1062, height: 0.1326)),   // stop
        CapSprite(center: CGPoint(x: 0.6086, y: 0.9085), size: CGSize(width: 0.1043, height: 0.1311)),   // ff
        CapSprite(center: CGPoint(x: 0.7124, y: 0.9085), size: CGSize(width: 0.0996, height: 0.1311))    // rec
    ]

    // Continuously-integrated rotation (smooth, pause-clean). Both reels spin in lockstep —
    // the physically-accurate differential speeds read as a glitch at mini-player size.
    @State private var reelAngle: Double = 0
    @State private var lastTick: Date? = nil
    @State private var pressedIndex: Int? = nil   // transport button currently held
    @State private var scrubTime: TimeInterval? = nil   // live scrub preview on the tape window
    @State private var deckHovered = false        // pointer over the deck — reveals quiet chrome

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                deckImage(w, h)
                reels(w, h)
                capsLayer(w, h)
                DeckDragSurface(passthrough: Self.controlZones, onMagnify: onMagnify,
                                onResizeEnd: onResizeEnd,
                                scrubZone: Self.tapeWindow,
                                rulerSpan: Self.rulerStartX...Self.rulerEndX,
                                onScrubChanged: { f in
                                    scrubTime = Double(f) * totalDuration
                                },
                                onScrubEnded: { f in
                                    scrubTime = nil
                                    onSeek(Double(f) * totalDuration)
                                },
                                onHoverChanged: { hovering in
                                    deckHovered = hovering
                                })
                buttonHotspots(w, h)
                speedPill(w, h)
                transcriptChip(w, h)
                tapeTimeline(w, h)
            }
            .frame(width: w, height: h)
        }
        // Fills whatever the panel proposes, aspect-locked — the panel's frame is the one
        // source of truth for size, so pinch/slider resizing is just a panel setFrame.
        .aspectRatio(Self.aspect, contentMode: .fit)
        // No clip and no drop shadow: the body PNG's alpha IS the silhouette, presented flat.
    }

    /// Unit-square regions the drag surface must NOT claim (fractions of the deck face):
    /// the padded transport strip, the speed marking under C-90, the TRANSCRIPT marking
    /// mirroring it under TAPE I, the top-left close/queue chips, and the elapsed counter on the
    /// tape window. The rest of the tape window stays with the drag surface — it scrubs itself;
    /// the counter is carved out of it so tapping the readout can't read as dropping the needle.
    private static let controlZones: [CGRect] = [
        CGRect(x: 0.24, y: 0.80, width: 0.54, height: 0.17),
        CGRect(x: 0.69, y: 0.625, width: 0.14, height: 0.07),
        CGRect(x: 0.17, y: 0.625, width: 0.14, height: 0.07),
        CGRect(x: 0.00, y: 0.00, width: 0.30, height: 0.13),
        CGRect(x: 0.4525, y: 0.4945, width: 0.09, height: 0.055)
    ]

    @ViewBuilder
    private func deckImage(_ w: CGFloat, _ h: CGFloat) -> some View {
        if let img = CassetteAsset.deck {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: w, height: h)
        } else {
            // Fallback if the resource is missing.
            ZStack {
                Color(.sRGB, red: 0.10, green: 0.10, blue: 0.11, opacity: 1)
                Text("cassette-deck.png missing").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: w, height: h)
        }
    }

    /// The two spinning reels, driven by a per-frame integrator so motion is buttery and freezes
    /// cleanly on pause. Only the sprites redraw each frame; the deck image is static.
    private func reels(_ w: CGFloat, _ h: CGFloat) -> some View {
        TimelineView(.animation(paused: !(isPlaying || isBuffering))) { tl in
            ZStack {
                reelSprite(CassetteAsset.reelLeft, center: Self.leftReel,
                           diameter: Self.leftReelDia, w, h, angle: reelAngle)
                reelSprite(CassetteAsset.reelRight, center: Self.rightReel,
                           diameter: Self.rightReelDia, w, h, angle: reelAngle)
            }
            .onChange(of: tl.date) { date in advance(to: date) }
        }
    }

    /// Integrate elapsed time into the shared reel angle. Rate scales the per-frame delta, so
    /// changing playback speed changes spin speed without any jump — and FF/REW visibly rev the
    /// reels up and down. While buffering the reels creep instead of freezing: the deck is
    /// waiting on audio, not stopped, and a dead-still deck reads as a hang.
    private func advance(to date: Date) {
        defer { lastTick = date }
        guard isPlaying || isBuffering, let last = lastTick else { return }
        let dt = date.timeIntervalSince(last)
        guard dt > 0, dt < 0.5 else { return }          // discard backgrounded gaps / first tick
        let base = 100.0                                 // deg/sec at 1×
        reelAngle += base * (isPlaying ? max(0.1, rate) : 0.22) * dt
    }

    /// A real cut-out reel layered over the deck: a dark backing disc hides whatever the body
    /// art shows behind the spoke gaps, and the sprite rotates about its own center — the sprite
    /// was extracted hub-centered from the same canvas as the body, so registration and spin are
    /// exact by construction. No masking, no wobble.
    @ViewBuilder
    private func reelSprite(_ sprite: NSImage?, center c: CGPoint, diameter: CGFloat,
                            _ w: CGFloat, _ h: CGFloat, angle: Double) -> some View {
        if let sprite {
            let d = diameter * w
            ZStack {
                Circle()
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.05))
                    .frame(width: d * 0.92, height: d * 0.92)
                Image(nsImage: sprite)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: d, height: d)
                    .rotationEffect(.degrees(angle))
            }
            .position(x: c.x * w, y: c.y * h)
            .allowsHitTesting(false)
        }
    }

    /// Real cap sprites layered over the baked caps — pixel-registered, so invisible at rest.
    /// A pressed cap sinks into a dark recess with a slight shrink and shade: genuine depth,
    /// crisp icon (it moves WITH the cap), no masked-pixel smearing.
    private func capsLayer(_ w: CGFloat, _ h: CGFloat) -> some View {
        ForEach(0..<5, id: \.self) { i in
            let cap = Self.capSprites[i]
            let cw = cap.size.width * w, ch = cap.size.height * h
            let pressed = isCapPressed(i)
            ZStack {
                // The recess revealed as the cap sinks; hidden at rest (sprite covers it exactly).
                RoundedRectangle(cornerRadius: w * 0.009, style: .continuous)
                    .fill(Color(red: 0.035, green: 0.035, blue: 0.04))
                    .frame(width: cw - 2, height: ch - 2)
                    .opacity(pressed ? 1 : 0)
                if let img = CassetteAsset.caps[i] {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: cw, height: ch)
                        .scaleEffect(pressed ? 0.96 : 1.0)
                        .offset(y: pressed ? w * 0.0076 : 0)   // sink travel scales with deck size
                        .brightness(pressed ? -0.08 : 0)
                }
            }
            .position(x: cap.center.x * w, y: cap.center.y * h)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.08), value: pressed)
        }
    }

    private func isCapPressed(_ i: Int) -> Bool {
        pressedIndex == i
            || (i == 1 && (isPlaying || isBuffering))
            || (i == 4 && isRecording)
    }

    /// The transport is built on SwiftUI Button — the only interaction primitive that reliably
    /// fires in this borderless, non-activating panel (DragGesture never engages there).
    private func buttonHotspots(_ w: CGFloat, _ h: CGFloat) -> some View {
        let acts: [() -> Void] = [onSkipBack, onPlayPause, onStop, onSkipForward, onToggleRecord]
        let names = ["Back 10 seconds", "Play / Pause", "Stop", "Forward 10 seconds", "Conversation Mode"]
        return ForEach(0..<5, id: \.self) { i in
            // Click target is taller than the visual cap so the transport stays easy to hit;
            // the pressed-cap mask uses the exact cap rect.
            let bw = Self.btnWs[i] * w, bh = Self.btnH * h * 1.5
            Button {
                Log.app.info("Deck: \(names[i], privacy: .public) activated")
                acts[i]()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: bw, height: bh)
            }
            .buttonStyle(HotspotButtonStyle { pressed in
                if pressed {
                    pressedIndex = i
                } else if pressedIndex == i {
                    pressedIndex = nil
                }
            })
            .position(x: Self.btnXs[i] * w, y: Self.btnY * h)
            .help(names[i])
        }
    }

    /// Invisible plain style that reports continuous pressed state — drives the sunk-cap visual
    /// while the mouse is held down on a transport button.
    private struct HotspotButtonStyle: ButtonStyle {
        let onPressChanged: (Bool) -> Void
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { pressed in onPressChanged(pressed) }
        }
    }

    /// Speed marking printed in the cassette shell's bottom-right corner, on the TDK line —
    /// same print styles as the label column (white like TAPE I at 1×, tape yellow like C-90
    /// once changed). Quiet by design: hidden at 1× until the pointer is over the deck
    /// (which is exactly when it's clickable), persistent once the speed is off default.
    private func speedPill(_ w: CGFloat, _ h: CGFloat) -> some View {
        let offDefault = rate != 1.0
        let visible = offDefault || deckHovered
        return Button(action: onCycleSpeed) {
            Text(speedLabel)
                .font(.system(size: max(8, w * 0.0235), weight: .black))
                .foregroundStyle(offDefault ? Self.tapeYellow.opacity(0.92) : .white.opacity(0.85))
                .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)
                // Right-anchored so longer labels (1.25×) grow leftward into the shell,
                // never poking out past the corner; the frame doubles as the click target.
                .frame(width: 0.13 * w, alignment: .trailing)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Playback speed")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.15), value: visible)
        .position(x: 0.757 * w, y: 0.66 * h)
    }

    /// Liner-notes call-out printed on the shell's bottom-left, mirroring the speed marking on the
    /// right. Same quiet rule as the speed pill: hidden until the pointer is over the deck (which
    /// is exactly when it's clickable), and lit in tape yellow while the notes are open.
    private func transcriptChip(_ w: CGFloat, _ h: CGFloat) -> some View {
        let visible = hasTranscript && (deckHovered || isTranscriptOpen)
        return Button(action: onToggleTranscript) {
            Text("TRANSCRIPT")
                .font(.system(size: max(7, w * 0.0195), weight: .black))
                .foregroundStyle(isTranscriptOpen ? Self.tapeYellow.opacity(0.92) : .white.opacity(0.85))
                .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // Left-anchored, mirroring the speed pill's right anchor, so both markings grow
                // inward from their own edge of the shell.
                .frame(width: 0.13 * w, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isTranscriptOpen ? "Hide liner notes" : "Liner notes — read along and jump around")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.15), value: visible)
        .position(x: 0.243 * w, y: 0.66 * h)
    }

    // MARK: Tape-window timeline

    /// The cassette's tape window doubles as the timeline: the baked tick ruler is the scale
    /// and a tape-yellow playhead (grab dot + needle) rides it. The whole window is the scrub
    /// surface — the deck's AppKit drag surface reports the drags (SwiftUI gestures never
    /// engage in this non-activating panel) and this view draws the feedback. Geometry
    /// measured from the art.
    private static let tapeWindow = CGRect(x: 0.392, y: 0.385, width: 0.215, height: 0.16)
    private static let rulerStartX: CGFloat = 0.412
    private static let rulerEndX: CGFloat = 0.583
    private static let rulerY: CGFloat = 0.462
    private static let tapeYellow = Color(red: 221/255, green: 201/255, blue: 139/255)

    /// x for a 0…1 position along the ruler.
    private static func rulerX(_ frac: CGFloat, _ w: CGFloat) -> CGFloat {
        (rulerStartX + min(max(frac, 0), 1) * (rulerEndX - rulerStartX)) * w
    }

    private func isLoaded(_ t: TimeInterval) -> Bool {
        bufferedRanges.contains { $0.lowerBound <= t && t <= $0.upperBound }
    }

    /// Where the tape is filling to right now: the trailing edge of the loaded run the playhead
    /// sits in — synthesis always works forward from the playhead (see `nextSynthIndex`). Nil
    /// when the playhead is itself in a gap, because then the thing being loaded IS the
    /// playhead's own segment and the needle halo carries that instead.
    private func loadingFrontier(at t: TimeInterval) -> TimeInterval? {
        guard let run = bufferedRanges.first(where: { $0.lowerBound <= t && t <= $0.upperBound })
        else { return nil }
        return run.upperBound < totalDuration * 0.995 ? run.upperBound : nil
    }

    private func tapeTimeline(_ w: CGFloat, _ h: CGFloat) -> some View {
        let shown = scrubTime ?? currentTime
        let frac = totalDuration > 0 ? CGFloat(min(max(shown / totalDuration, 0), 1)) : 0
        let needleX = Self.rulerX(frac, w)
        // Loaded-tape chrome vanishes once everything is synthesized — at that point every scrub
        // is instant and the marks carry no information.
        let covered = bufferedRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        let loading = totalDuration > 0 && covered < totalDuration * 0.995
        let onLoadedTape = isLoaded(shown)
        // The needle waits in place, mid-gap, until its segment lands — the halo says so.
        // Not while scrubbing: there the needle is a preview, and the dimmed needle plus the
        // chip's ellipsis already say "this stretch isn't made yet".
        let parked = loading && isBuffering && scrubTime == nil && !onLoadedTape

        return ZStack {
            if loading {
                // Unloaded rail: the full span drawn faint, so the loaded stretch reads as a
                // fill against it rather than as a stray mark on the ruler.
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(width: (Self.rulerEndX - Self.rulerStartX) * w, height: max(1, 0.008 * h))
                    .position(x: (Self.rulerStartX + Self.rulerEndX) / 2 * w, y: Self.rulerY * h)
                    .allowsHitTesting(false)

                // Loaded tape: the stretch whose audio exists — drop the needle inside it and
                // playback is instant; outside, the deck buffers until that segment is made.
                ForEach(bufferedRanges.indices, id: \.self) { i in
                    let x0 = Self.rulerX(CGFloat(bufferedRanges[i].lowerBound / totalDuration), w)
                    let x1 = Self.rulerX(CGFloat(bufferedRanges[i].upperBound / totalDuration), w)
                    Capsule()
                        .fill(.white.opacity(0.42))
                        .frame(width: max(1, x1 - x0), height: max(1, 0.010 * h))
                        .position(x: (x0 + x1) / 2, y: Self.rulerY * h)
                        .allowsHitTesting(false)
                }

                // Anchored on the real playhead, not `shown`: the bead marks where synthesis is
                // actually working, so it holds still while a scrub previews somewhere else.
                LoadingPulse(
                    frontierX: loadingFrontier(at: currentTime).map {
                        Self.rulerX(CGFloat($0 / totalDuration), w)
                    },
                    haloX: parked ? needleX : nil,
                    w: w, h: h)
            }

            // Playhead needle straddling the ruler line. A scrub aiming past the loaded tape
            // dims it: dropping here means waiting for that stretch to be made.
            RoundedRectangle(cornerRadius: 1)
                .fill(Self.tapeYellow)
                .opacity(scrubTime != nil && loading && !onLoadedTape ? 0.5 : 1)
                .frame(width: max(1.5, w * 0.004), height: 0.085 * h)
                .shadow(color: .black.opacity(0.8), radius: 1)
                .position(x: needleX, y: Self.rulerY * h)
                .allowsHitTesting(false)

            // Elapsed readout printed on the window glass, tucked between the tape packs. It
            // doubles as the transcript toggle: it's the one spot on the timeline that isn't the
            // scrub groove (carved out of the scrub zone in controlZones), so tapping the readout
            // can never be mistaken for dropping the needle.
            Button(action: onToggleTranscript) {
                Text(Self.format(shown))
                    .font(.system(size: max(7, w * 0.015), weight: .heavy, design: .monospaced))
                    .foregroundStyle(isTranscriptOpen ? Self.tapeYellow.opacity(0.95) : .white.opacity(0.75))
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(hasTranscript)
            .help(isTranscriptOpen ? "Hide liner notes" : "Read along — opens the liner notes")
            .position(x: 0.4975 * w, y: 0.522 * h)

            // Scrub-target chip, only while dragging. The ellipsis is the "this stretch isn't
            // made yet — you'll wait a moment here" tell, matching the dimmed needle.
            if scrubTime != nil {
                let willWait = loading && !onLoadedTape
                Text("\(Self.format(shown)) · -\(Self.format(max(0, totalDuration - shown)))"
                     + (willWait ? " ⋯" : ""))
                    .font(.system(size: max(7, w * 0.018), weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .position(x: min(max(needleX, 0.44 * w), 0.56 * w), y: 0.368 * h)
                    .allowsHitTesting(false)
            }

        }
    }

    /// The one animated layer of the timeline, isolated in its own TimelineView so the static
    /// chrome (rail, loaded marks, needle, counter) isn't relaid out every frame:
    ///  · a bead breathing at the point the tape is filling to, and
    ///  · a halo around the needle when the playhead is parked in a gap waiting on its own audio.
    /// One shared phase, so the two pulse together instead of drifting apart.
    private struct LoadingPulse: View {
        let frontierX: CGFloat?
        let haloX: CGFloat?
        let w: CGFloat
        let h: CGFloat

        var body: some View {
            TimelineView(.animation) { tl in
                let breath = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 3.0)
                ZStack {
                    if let x = frontierX {
                        Capsule()
                            .fill(.white)
                            .frame(width: max(1.5, w * 0.006), height: max(1.5, 0.013 * h))
                            .opacity(0.25 + 0.6 * breath)
                            .position(x: x, y: CassetteDeckView.rulerY * h)
                    }
                    if let x = haloX {
                        Capsule()
                            .fill(CassetteDeckView.tapeYellow)
                            .frame(width: max(3, w * 0.015), height: 0.085 * h)
                            .blur(radius: max(1.5, w * 0.007))
                            .opacity(0.14 + 0.5 * breath)
                            .position(x: x, y: CassetteDeckView.rulerY * h)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Host (observes the live player)

struct CassettePlayerHost: View {
    @ObservedObject var streamer: SentenceStreamPlayer
    @ObservedObject var coordinator: TTSCoordinator
    /// Observed so the REC cap latches/releases live when Conversation Mode toggles.
    @ObservedObject var appState: AppState
    let reading: ReadingItem
    let onPlayPause: () -> Void
    let onStop: () -> Void
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void
    let onCycleSpeed: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onMagnify: (CGFloat) -> Void
    let onResizeEnd: (CGFloat) -> Void

    private var speedLabel: String { "\(String(format: "%g", Double(streamer.rate)))×" }

    var body: some View {
        CassetteDeckView(
            isPlaying: streamer.state == .playing,
            isBuffering: streamer.state == .bufferingFirstAudio,
            isRecording: appState.conversationModeEnabled,
            rate: Double(streamer.rate),
            speedLabel: speedLabel,
            currentTime: streamer.currentTime,
            totalDuration: streamer.totalDuration,
            bufferedRanges: streamer.bufferedRanges,
            hasTranscript: !streamer.transcript.isEmpty,
            isTranscriptOpen: appState.transcriptVisible,
            onPlayPause: onPlayPause,
            onStop: onStop,
            onSkipBack: onSkipBack,
            onSkipForward: onSkipForward,
            onCycleSpeed: onCycleSpeed,
            onToggleRecord: { appState.conversationModeEnabled.toggle() },
            onSeek: onSeek,
            onToggleTranscript: { appState.transcriptVisible.toggle() },
            onMagnify: onMagnify,
            onResizeEnd: onResizeEnd
        )
        .overlay(alignment: .topLeading) {
            // Queue badge only — STOP on the transport is the close control.
            if coordinator.queueCount > 0 {
                Button { coordinator.skipToNext() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "forward.end.fill")
                        Text("\(coordinator.queueCount)")
                    }
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Skip to next (\(coordinator.queueCount) queued)")
                .padding(10)
            }
        }
    }
}
