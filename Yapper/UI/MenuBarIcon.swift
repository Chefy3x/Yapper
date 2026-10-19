import SwiftUI

struct MenuBarIcon: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.voiceInputState {
        case .listening:
            // macOS already puts its own orange mic indicator in the menu bar whenever the
            // mic is open; a second mic here just reads as a duplicate. Keep the brand mark.
            Image("MenuBarMark")
                .renderingMode(.template)
        case .transcribing:
            // No mic glyph either: the system indicator lingers a few seconds after the mic
            // closes, so a mic here would still double up.
            Image(systemName: "ellipsis")
        case .idle:
            // Reading is a state worth reporting, so the waveform keeps that slot; the brand
            // mark only takes over when there is nothing happening to describe.
            if state.isReading {
                // `.symbolEffect` needs macOS 14; on Ventura the icon is static.
                if #available(macOS 14, *) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "waveform")
                }
            } else {
                // Authored at 19x16pt so it matches the optical weight of the SF Symbols
                // above it; template rendering lets the menu bar tint it for light/dark.
                Image("MenuBarMark")
                    .renderingMode(.template)
            }
        }
    }
}
