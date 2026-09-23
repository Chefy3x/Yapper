import SwiftUI
import AppKit

/// The deck's liner notes: the read's text, split into sentences, each stamped with the time it
/// starts. The line being spoken highlights and the list follows it; click any line to drop the
/// needle there. Lines whose audio isn't synthesized yet are dimmed — clicking one still works,
/// it just parks the deck there until the pipeline reaches it (same as scrubbing past the buffer).
///
/// Lives in its own panel child-windowed to the player, so the deck art stays a fixed-aspect
/// cutout and the notes can be as tall as they need to be.
struct TranscriptView: View {
    @ObservedObject var streamer: SentenceStreamPlayer
    let sourceApp: String
    let onSeek: (TimeInterval) -> Void
    let onClose: () -> Void

    /// The user scrolling by hand suspends auto-follow until the needle moves on its own again —
    /// otherwise reading ahead is impossible, the list keeps yanking back to the spoken line.
    @State private var following = true
    @State private var hoveredID: Int? = nil

    private static let shadowRadius: CGFloat = 12
    private static let shadowY: CGFloat = 6
    private static let shadowOpacity = 0.45
    /// Transparent border around the card that the drop shadow draws into. It is part of the
    /// view's own size so the panel includes it — a panel cut to the card clips the shadow away.
    /// SwiftUI's shadow radius behaves like a Gaussian σ; at this darker opacity the shadow needs
    /// ~2.2σ past its offset to fade under 2/255 (the player's 0.25 gets there by 1.9σ). Every
    /// pixel of the margin that isn't fully clear takes clicks, which is why the radius is 12 and
    /// not a wider 18: that would need a 40pt border.
    static let shadowMargin: EdgeInsets = {
        let reach = (shadowRadius * 2.2).rounded(.up)
        return EdgeInsets(top: reach - shadowY, leading: reach, bottom: reach + shadowY, trailing: reach)
    }()

    private var currentID: Int? {
        streamer.transcript.first { $0.contains(streamer.currentTime) }?.id
            ?? streamer.transcript.last { $0.start <= streamer.currentTime }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            DashedHairline()
                .padding(.horizontal, 12)
            lines
        }
        .background(Tape.void)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Tape.line, lineWidth: 1)
        )
        // Flatten first so the card casts one shadow — otherwise every line of text casts its own
        // onto the notes.
        .compositingGroup()
        .shadow(color: .black.opacity(Self.shadowOpacity), radius: Self.shadowRadius, y: Self.shadowY)
        .padding(Self.shadowMargin)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("LINER NOTES")
                .font(Tape.shout(13))
                .foregroundStyle(Tape.cream)
            Text(sourceApp.uppercased())
                .font(Tape.mono(9, .semibold))
                .foregroundStyle(Tape.faint)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !following {
                Button {
                    following = true
                } label: {
                    Text("FOLLOW")
                        .font(Tape.mono(9, .bold))
                        .foregroundStyle(Tape.yellow)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Tape.yellow.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Jump back to the line playing now")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tape.dust)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close liner notes")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(WindowDragHandle())   // header doubles as the drag area for the notes panel
    }

    @ViewBuilder
    private var lines: some View {
        if streamer.transcript.isEmpty {
            Text("No text stored for this read.")
                .font(Tape.mono(11))
                .foregroundStyle(Tape.faint)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(streamer.transcript) { line in
                            row(line)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .overlay(ScrollFollowBreaker { if following { following = false } })
                .onChange(of: currentID) { id in
                    guard following, let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: following) { on in
                    guard on, let id = currentID else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = currentID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func row(_ line: SentenceStreamPlayer.TranscriptLine) -> some View {
        let isCurrent = line.id == currentID
        let isPast = line.end <= streamer.currentTime && !isCurrent
        let hovered = hoveredID == line.id

        return Button {
            following = true
            onSeek(line.start)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Time gutter — the "click me to jump here" tell, and a real timestamp to boot.
                Text(Self.stamp(line.start))
                    .font(Tape.mono(9, isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? Tape.yellow : Tape.cream.opacity(0.30))
                    .frame(width: 30, alignment: .trailing)

                Text(line.text)
                    .font(Tape.mono(11, isCurrent ? .semibold : .regular))
                    .foregroundStyle(color(current: isCurrent, past: isPast, line: line))
                    .strikethrough(line.isFailed, color: Tape.faint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Tape.yellow.opacity(0.10)
                          : (hovered ? Color.white.opacity(0.05) : .clear))
            )
            .overlay(alignment: .leading) {
                // Yellow rule down the spoken line — the needle, in the margin.
                if isCurrent {
                    Capsule()
                        .fill(Tape.yellow)
                        .frame(width: 2)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? line.id : (hoveredID == line.id ? nil : hoveredID) }
        .help(line.isFailed ? "This part failed to synthesize"
              : (line.isLoaded ? "Jump to \(Self.stamp(line.start))"
                 : "Jump to \(Self.stamp(line.start)) — not loaded yet, the deck will buffer here"))
    }

    /// Spoken lines recede, the unread stay bright, and anything not yet synthesized sits between
    /// the two — visibly there, visibly not ready.
    private func color(current: Bool, past: Bool, line: SentenceStreamPlayer.TranscriptLine) -> Color {
        if line.isFailed { return Tape.cream.opacity(0.26) }
        if current { return Tape.yellow }
        if !line.isLoaded { return Tape.cream.opacity(0.32) }
        return past ? Tape.cream.opacity(0.50) : Tape.cream.opacity(0.86)
    }

    private static func stamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Scroll-wheel detector: any wheel event over the notes drops auto-follow, so the user can read
/// ahead without the list snapping back. SwiftUI has no scroll-began hook on macOS 13, and the
/// panel never becomes key — an AppKit overlay that observes (and passes through) wheel events is
/// the reliable way to notice.
struct ScrollFollowBreaker: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WheelView()
        v.onUserScroll = onUserScroll
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WheelView)?.onUserScroll = onUserScroll
    }

    final class WheelView: NSView {
        var onUserScroll: (() -> Void)?
        // Never claim clicks or the wheel itself — the ScrollView underneath must keep both.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The token is held in a box so `deinit` (which is nonisolated) can release it without
        /// reaching into MainActor state.
        private final class Token: @unchecked Sendable {
            var value: Any?
            func release() {
                if let value { NSEvent.removeMonitor(value) }
                value = nil
            }
        }
        private let token = Token()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return token.release() }
            guard token.value == nil else { return }
            token.value = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Only this panel's own wheel events count — the monitor is app-wide.
                guard let self, let window = self.window, event.window === window else { return event }
                self.onUserScroll?()
                return event
            }
        }

        deinit { token.release() }
    }
}
