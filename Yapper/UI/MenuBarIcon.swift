import SwiftUI

struct MenuBarIcon: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.isReading {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            Image(systemName: "waveform")
        }
    }
}
