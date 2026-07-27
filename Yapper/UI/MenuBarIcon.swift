import SwiftUI

struct MenuBarIcon: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // `.symbolEffect` needs macOS 14; on Ventura the icon is static.
        if state.isReading, #available(macOS 14, *) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            Image(systemName: "waveform")
        }
    }
}
