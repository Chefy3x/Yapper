import SwiftUI

struct MenuBarIcon: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.voiceInputState {
        case .listening:
            // The mic is open — say so where the eye already goes.
            Image(systemName: "mic.fill")
        case .transcribing:
            Image(systemName: "waveform.and.mic")
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
