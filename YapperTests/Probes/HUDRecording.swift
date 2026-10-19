import Testing
import AppKit
import SwiftUI

/// Opt-in: puts the real recording pill on screen, drives it through a whole turn with made-up
/// mic levels, and screen-records it so the motion can be checked frame by frame.
/// Set YAPPER_HUD_RECORDING=<output folder> (TEST_RUNNER_YAPPER_HUD_RECORDING through xcodebuild).
/// The test process usually can't screen-record, so it writes the pill's screen rect to
/// rect.txt; a recorder started alongside it (screencapture -v -R) films it, touching `go` once
/// it's rolling and `stop` once it's done, and the probe waits for each.
@MainActor
struct HUDRecording {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YAPPER_HUD_RECORDING"]

    @Test(.enabled(if: outDir != nil)) func recordATurn() async throws {
        let out = URL(fileURLWithPath: Self.outDir!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let hud = RecordingHUDPresenter()

        // Show it once off the clock so the panel exists and its frame is known, then let it go.
        hud.listen(locked: false, handsFree: false)
        hud.close()
        try await Task.sleep(for: .seconds(0.6))
        guard let frame = hud.frame, let screen = NSScreen.main else { return }
        // screencapture wants top-left origin points.
        let top = screen.frame.maxY - frame.maxY
        // A plain backdrop just under the pill, so whatever is on screen doesn't muddy the film.
        let backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(Brand.canvas)
        backdrop.level = .floating
        backdrop.ignoresMouseEvents = true
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }
        let rect = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"

        try rect.write(to: out.appendingPathComponent("rect.txt"), atomically: true, encoding: .utf8)
        try await Self.waitFor(out.appendingPathComponent("go"))
        try await Task.sleep(for: .seconds(0.5))

        hud.listen(locked: false, handsFree: false)
        // About two seconds of speech-like level at the rate the mic delivers it (~12 a second).
        let start = Date()
        var n = 0
        while Date().timeIntervalSince(start) < 2.0 {
            let t = Date().timeIntervalSince(start)
            let syllable = 0.5 + 0.5 * sin(t * 2 * .pi * 3.1) * sin(t * 2 * .pi * 0.7 + 1)
            let db = -50 + 38 * max(0, syllable) + Double((n * 7919) % 7) - 3
            hud.level(Float(pow(10, db / 20)))
            n += 1
            try await Task.sleep(for: .milliseconds(85))
        }
        hud.work()
        try await Task.sleep(for: .seconds(0.9))
        hud.react(.done)            // the words landed: the mouth grins, then the pill closes
        try await Self.waitFor(out.appendingPathComponent("stop"))
    }

    private static func waitFor(_ file: URL) async throws {
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
