import SwiftUI

/// A provider credential, and everything that differs between them.
enum KeyedProvider {
    case elevenLabs, openAI

    var account: Keychain.Account {
        switch self {
        case .elevenLabs: .elevenLabsKey
        case .openAI:     .openAIKey
        }
    }

    var displayName: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAI:     "OpenAI"
        }
    }

    var placeholder: String {
        switch self {
        case .elevenLabs: "xi-•••••••••••••••••••••••"
        case .openAI:     "sk-•••••••••••••••••••••••"
        }
    }

    /// Where the key actually comes from. Without this, the field asks for something the user has
    /// no stated way of obtaining.
    var consoleURL: URL {
        switch self {
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/developers/api-keys")!
        case .openAI:     URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    func validate(_ key: String) async -> APIKeyCheck {
        switch self {
        case .elevenLabs: await ElevenLabsClient.validate(apiKey: key)
        case .openAI:     await OpenAIClient.validate(apiKey: key)
        }
    }
}

/// One API key field: paste, check, store.
///
/// Shared by the first-run guide and Settings so the two can never drift into disagreeing about
/// what a saved key means. The check runs *before* the write, so a credential the provider has
/// already rejected never reaches the Keychain.
struct APIKeyField: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.settingsSkin) private var skin

    let provider: KeyedProvider
    /// Rendered next to Save once a key is actually stored — the guide uses it for "Hear it".
    var previewAction: (() -> Void)? = nil
    var onSaved: (() -> Void)? = nil

    @State private var key = ""
    @State private var status: Status = .idle
    /// The field arrives pre-filled when a key is already in the Keychain. Saying so out loud
    /// stops it reading as a mystery credential the app produced from somewhere.
    @State private var loadedFromKeychain = false

    enum Status: Equatable {
        case idle
        case checking
        case verified                 // checked, accepted, written to the Keychain
        case rejected                 // checked, refused — deliberately not written
        case savedUnverified(String)  // written, but the check never reached a verdict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(provider.displayName) API key")
                    .font(skin.body(12.5, .semibold))
                Spacer(minLength: 0)
                Link("Get a key", destination: provider.consoleURL)
                    .font(skin.body(10.5, .medium))
            }

            SecureField(provider.placeholder, text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            // Status above the buttons rather than beside them: "couldn't reach ElevenLabs to
            // check it" is too long to share a row with two controls.
            statusLine

            HStack(spacing: 10) {
                Spacer()
                if isStored, let previewAction {
                    Button("Hear it", action: previewAction)
                }
                Button(status == .checking ? "Checking…" : "Save key") {
                    Task { await save() }
                }
                .disabled(trimmed.isEmpty || status == .checking)
            }
        }
        .onAppear {
            let existing = state.keychain.get(provider.account) ?? ""
            key = existing
            loadedFromKeychain = !existing.isEmpty
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .idle:
            if loadedFromKeychain {
                Text("Using the key already saved in your Keychain.")
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Checking with \(provider.displayName)…")
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
            }
        case .verified:
            line("checkmark.circle.fill", skin.okTint, "Connected. Key saved to your Keychain.")
        case .rejected:
            line("xmark.circle.fill", .orange,
                 "\(provider.displayName) wouldn't accept that key, so it wasn't saved.")
        case .savedUnverified(let why):
            line("exclamationmark.circle.fill", .orange,
                 "Saved, but couldn't reach \(provider.displayName) to check it.")
                .help(why)
        }
    }

    private func line(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(skin.body(11, .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    // MARK: - Behaviour

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True once a key is actually in the Keychain — whether or not the check reached a verdict.
    private var isStored: Bool {
        switch status {
        case .verified, .savedUnverified: true
        case .idle:                       loadedFromKeychain
        default:                          false
        }
    }

    private func save() async {
        let candidate = trimmed
        guard !candidate.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) { status = .checking }

        switch await provider.validate(candidate) {
        case .valid:
            state.keychain.set(candidate, for: provider.account)
            withAnimation { status = .verified }
            onSaved?()
        case .rejected:
            withAnimation { status = .rejected }
        case .inconclusive(let why):
            // No verdict means no grounds to refuse it. Setting up on a plane is a real thing, and
            // discarding a key we never actually disproved would be the worse failure.
            state.keychain.set(candidate, for: provider.account)
            withAnimation { status = .savedUnverified(why) }
            onSaved?()
        }
    }
}
