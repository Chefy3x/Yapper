import SwiftUI
import AppKit

/// Wraps an NSView whose mouseDown immediately starts a native window drag. Layer it on top of
/// (or behind) the SwiftUI controls you want to act as the drag handle.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHostView { DragHostView() }
    func updateNSView(_ nsView: DragHostView, context: Context) {}

    final class DragHostView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct MiniPlayerView: View {
    @ObservedObject var streamer: SentenceStreamPlayer
    @ObservedObject var coordinator: TTSCoordinator
    let reading: ReadingItem
    let onPlayPause: () -> Void
    let onClose: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onCycleSpeed: () -> Void

    private var isPlaying: Bool { streamer.state == .playing }
    private var isBuffering: Bool { streamer.state == .bufferingFirstAudio }

    private static let accent = Color(red: 105/255, green: 144/255, blue: 191/255)   // KeepCo blue

    private var speedLabel: String {
        "\(String(format: "%g", Double(streamer.rate)))×"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(reading.sourceApp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if coordinator.queueCount > 0 {
                    Text("+\(coordinator.queueCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Self.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Self.accent.opacity(0.15), in: Capsule())
                        .help("\(coordinator.queueCount) more queued")
                }
                Spacer()
                Button(action: onCycleSpeed) {
                    Text(speedLabel)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(streamer.rate == 1.0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.accent))
                        .frame(minWidth: 24)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Playback speed")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            .background(WindowDragHandle())   // header doubles as the drag area

            Text(reading.preview)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .background(WindowDragHandle())   // preview row also drags
                .help("Drag to move")

            HStack(spacing: 10) {
                Button(action: onPlayPause) {
                    Image(systemName: isBuffering ? "ellipsis" : (isPlaying ? "pause.fill" : "play.fill"))
                        .font(.body.weight(.semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBuffering)

                if coordinator.queueCount > 0 {
                    Button { coordinator.skipToNext() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.caption.weight(.semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Skip to next (\(coordinator.queueCount) queued)")
                }

                ScrubberSlider(
                    value: streamer.currentTime,
                    range: 0...max(streamer.totalDuration, 0.1),
                    onScrub: onSeek
                )
                .accentColor(Color(red: 105/255, green: 144/255, blue: 191/255))   // KeepCo blue

                Text(timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 320, height: 80)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private var timeLabel: String {
        "\(format(streamer.currentTime)) / \(format(streamer.totalDuration))"
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Slider with a visible thumb. Click anywhere on the track to seek, or drag the thumb.
struct ScrubberSlider: View {
    let value: TimeInterval
    let range: ClosedRange<TimeInterval>
    let onScrub: (TimeInterval) -> Void

    @State private var dragging: TimeInterval?

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let progress = dragging ?? value
            let pct: CGFloat = range.upperBound > 0
                ? CGFloat(min(max((progress - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1))
                : 0
            let usableWidth = proxy.size.width - thumbSize
            let thumbX = usableWidth * pct

            ZStack(alignment: .leading) {
                // Inactive track
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbSize / 2)

                // Active (played) track
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbX + thumbSize / 2, height: trackHeight)
                    .padding(.leading, thumbSize / 2)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .offset(x: thumbX)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let clamped = max(thumbSize / 2, min(proxy.size.width - thumbSize / 2, gesture.location.x))
                        let rawPct = (clamped - thumbSize / 2) / usableWidth
                        dragging = range.lowerBound + Double(rawPct) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        if let dragging { onScrub(dragging) }
                        dragging = nil
                    }
            )
        }
        .frame(height: 18)
    }
}
