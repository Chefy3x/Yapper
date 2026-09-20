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
            // `.symbolEffect` needs macOS 14; on Ventura the icon is static.
            if state.isReading, #available(macOS 14, *) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else {
                Image(systemName: "waveform")
            }
        }
    }
}
