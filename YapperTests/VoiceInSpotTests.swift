import Testing
import AppKit

@MainActor
struct VoiceInSpotTests {
    /// A 1440×900 screen with the Dock taking the bottom 60 pt.
    let visible = NSRect(x: 0, y: 60, width: 1440, height: 840)
    let deck = NSSize(width: 360, height: 222)

    @Test func spotCoversThePillAndTheLiftedNote() {
        let spot = VoiceInSpot.rect(in: visible)
        #expect(spot.contains(RecordingHUDPresenter.frame(in: visible)))
        #expect(spot.contains(VoiceToastPresenter.frame(in: visible, lifted: false)))
        #expect(spot.contains(VoiceToastPresenter.frame(in: visible, lifted: true)))
        #expect(spot.midX == visible.midX && spot.minY == visible.minY)
    }

    @Test func liftedNoteSitsAboveThePill() {
        let pill = RecordingHUDPresenter.frame(in: visible)
        let note = VoiceToastPresenter.frame(in: visible, lifted: true)
        // The capsule sits 12 pt up inside the note's panel.
        #expect(note.minY + 12 == pill.maxY)
    }

    @Test func aCornerDeckStaysPut() {
        let body = NSRect(origin: NSPoint(x: visible.maxX - deck.width - 16, y: visible.minY + 16), size: deck)
        #expect(VoiceInSpot.clear(body, in: visible) == body.origin)
    }

    @Test func aDeckOnThePillMovesTheShortestWayOut() {
        let spot = VoiceInSpot.rect(in: visible).insetBy(dx: -VoiceInSpot.gap, dy: -VoiceInSpot.gap)
        // Overlapping the spot's right edge a little: the way out is to the right.
        let body = NSRect(origin: NSPoint(x: spot.maxX - 60, y: visible.minY + 16), size: deck)
        let cleared = VoiceInSpot.clear(body, in: visible)
        #expect(cleared == NSPoint(x: spot.maxX, y: body.minY))
        #expect(!NSRect(origin: cleared, size: deck).intersects(spot))
    }

    @Test func aDeckDeepInTheSpotRisesAboveIt() {
        let spot = VoiceInSpot.rect(in: visible).insetBy(dx: -VoiceInSpot.gap, dy: -VoiceInSpot.gap)
        // Centred on the pill, rising clear is shorter than crossing half the spot sideways.
        let body = NSRect(origin: NSPoint(x: visible.midX - deck.width / 2, y: visible.minY + 16), size: deck)
        #expect(VoiceInSpot.clear(body, in: visible) == NSPoint(x: body.minX, y: spot.maxY))
    }

    @Test func aWideDeckOnANarrowScreenGoesUp() {
        let narrow = NSRect(x: 0, y: 0, width: 900, height: 700)
        let wide = NSSize(width: 520, height: 320)
        let body = NSRect(origin: NSPoint(x: 190, y: 10), size: wide)
        let spot = VoiceInSpot.rect(in: narrow).insetBy(dx: -VoiceInSpot.gap, dy: -VoiceInSpot.gap)
        #expect(VoiceInSpot.clear(body, in: narrow) == NSPoint(x: 190, y: spot.maxY))
    }

    @Test func nowhereClearLeavesItWhereItIs() {
        let tiny = NSRect(x: 0, y: 0, width: 500, height: 300)
        let body = NSRect(origin: NSPoint(x: 0, y: 0), size: NSSize(width: 480, height: 200))
        #expect(VoiceInSpot.clear(body, in: tiny) == body.origin)
    }
}
