import Foundation
import Combine

/// User defaults wrapped in published properties. Sensitive material (API keys) lives in Keychain.
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    enum Key: String, CaseIterable {
        case activeVoiceID
        case conversationDefaultOn
        case conversationAllowlist
        case launchAtLogin
        case miniPlayerCornerX
        case miniPlayerCornerY
        case miniPlayerDefaultCorner
        case historyRetentionHours
        case fallbackOrder
        case useNativeVoiceOffline
        case elevenLabsModelID
        case openAIModelID
        case customVoicesJSON
        case playbackRate
        case miniPlayerTheme
        case cassetteScale
        case onboardingCompleted
        case voiceInputEnabled
        case whisperModelID
        case handsFreeEnabled
        case inputDeviceUID
        case yapperKey
    }

    @Published var activeVoiceID: String {
        didSet { defaults.set(activeVoiceID, forKey: Key.activeVoiceID.rawValue) }
    }
    @Published var conversationDefaultOn: Bool {
        didSet { defaults.set(conversationDefaultOn, forKey: Key.conversationDefaultOn.rawValue) }
    }
    /// Bundle IDs of apps Conversation Mode watches for new assistant responses.
    @Published var conversationAllowlist: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(conversationAllowlist) {
                defaults.set(data, forKey: Key.conversationAllowlist.rawValue)
            }
        }
    }
    @Published var historyRetentionHours: Int {
        didSet { defaults.set(historyRetentionHours, forKey: Key.historyRetentionHours.rawValue) }
    }
    @Published var useNativeVoiceOffline: Bool {
        didSet { defaults.set(useNativeVoiceOffline, forKey: Key.useNativeVoiceOffline.rawValue) }
    }
    @Published var elevenLabsModelID: String {
        didSet { defaults.set(elevenLabsModelID, forKey: Key.elevenLabsModelID.rawValue) }
    }
    @Published var openAIModelID: String {
        didSet { defaults.set(openAIModelID, forKey: Key.openAIModelID.rawValue) }
    }
    /// Last-used mini-player playback speed (1.0 = normal). Persists so a chosen speed sticks
    /// across reads instead of resetting to 1× every time.
    @Published var playbackRate: Double {
        didSet { defaults.set(playbackRate, forKey: Key.playbackRate.rawValue) }
    }
    @Published var customVoices: [VoicePreset] {
        didSet {
            if let data = try? JSONEncoder().encode(customVoices) {
                defaults.set(data, forKey: Key.customVoicesJSON.rawValue)
            }
        }
    }
    @Published var miniPlayerDefaultCorner: MiniPlayerCorner {
        didSet { defaults.set(miniPlayerDefaultCorner.rawValue, forKey: Key.miniPlayerDefaultCorner.rawValue) }
    }
    @Published var miniPlayerTheme: MiniPlayerTheme {
        didSet { defaults.set(miniPlayerTheme.rawValue, forKey: Key.miniPlayerTheme.rawValue) }
    }
    /// Bounds for the cassette deck size multiplier — one source of truth shared by the
    /// Settings slider, the pinch gesture, and window edge-resizing. The 0.75 floor keeps the
    /// deck from shrinking narrower than the minimal player (~336pt) — below that the transport
    /// and scrubber get too small to hit and the window feels stuck.
    static let cassetteScaleRange: ClosedRange<Double> = 0.75...1.6
    /// Cassette deck size multiplier (1.0 = the 446pt-wide design size). Set from the Settings
    /// slider, by pinching the deck, or by dragging the deck's edges like a regular window.
    @Published var cassetteScale: Double {
        didSet { defaults.set(cassetteScale, forKey: Key.cassetteScale.rawValue) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin.rawValue) }
    }
    @Published var settingsDesign: SettingsDesign {
        didSet { defaults.set(settingsDesign.rawValue, forKey: "settingsDesign") }
    }
    /// The first-run guide has been seen (or explicitly skipped). Never shown again once true.
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted.rawValue) }
    }

    // MARK: Voice In (hold the talk key to talk)

    /// Master switch for local speech-to-text. Off means the hold gesture does nothing.
    @Published var voiceInputEnabled: Bool {
        didSet { defaults.set(voiceInputEnabled, forKey: Key.voiceInputEnabled.rawValue) }
    }
    /// WhisperKit model variant. Defaults per architecture — see `WhisperModel.recommended`.
    @Published var whisperModelID: String {
        didSet { defaults.set(whisperModelID, forKey: Key.whisperModelID.rawValue) }
    }
    /// After a Conversation Mode reply finishes reading, open the mic until the user pauses.
    /// The transcript lands in the composer; Yapper never presses Return.
    @Published var handsFreeEnabled: Bool {
        didSet { defaults.set(handsFreeEnabled, forKey: Key.handsFreeEnabled.rawValue) }
    }
    /// The one modifier that drives Yapper (tap / hold / chords). See `YapperKey`.
    @Published var yapperKey: YapperKey {
        didSet { defaults.set(yapperKey.rawValue, forKey: Key.yapperKey.rawValue) }
    }
    /// CoreAudio device UID to record from. Nil = whatever macOS calls the default input.
    @Published var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID.rawValue) }
    }

    /// True when nothing has ever been persisted — a genuinely fresh install.
    ///
    /// Guards the first-run guide against firing for people who upgrade into this version:
    /// they have no `onboardingCompleted` flag either, and shipping them a setup wizard for an
    /// app they already use would be worse than shipping them nothing. Any other stored key
    /// means the app has been used, so the guide is suppressed and marked complete.
    static func looksLikeFirstRun(defaults: UserDefaults = .standard) -> Bool {
        let priorUse = Key.allCases
            .filter { $0 != .onboardingCompleted }
            .contains { defaults.object(forKey: $0.rawValue) != nil }
        return !priorUse
    }

    init() {
        self.activeVoiceID = defaults.string(forKey: Key.activeVoiceID.rawValue) ?? VoicePreset.defaultPreset.id
        self.conversationDefaultOn = defaults.bool(forKey: Key.conversationDefaultOn.rawValue)
        if let data = defaults.data(forKey: Key.conversationAllowlist.rawValue),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.conversationAllowlist = decoded
        } else {
            // Default to the apps with the most reliable, bespoke read strategies.
            self.conversationAllowlist = ["com.anthropic.claudefordesktop"]
        }
        self.historyRetentionHours = defaults.object(forKey: Key.historyRetentionHours.rawValue) as? Int ?? 24
        self.useNativeVoiceOffline = defaults.object(forKey: Key.useNativeVoiceOffline.rawValue) as? Bool ?? true
        let storedModel = defaults.string(forKey: Key.elevenLabsModelID.rawValue)
        // Migrate deprecated turbo_v2_5 → flash_v2_5
        if storedModel == "eleven_turbo_v2_5" {
            defaults.set(ElevenLabsModel.flashV25.id, forKey: Key.elevenLabsModelID.rawValue)
            self.elevenLabsModelID = ElevenLabsModel.flashV25.id
        } else {
            self.elevenLabsModelID = storedModel ?? ElevenLabsModel.defaultModel.id
        }

        if let data = defaults.data(forKey: Key.customVoicesJSON.rawValue),
           let decoded = try? JSONDecoder().decode([VoicePreset].self, from: data) {
            self.customVoices = decoded
        } else {
            self.customVoices = []
        }

        self.playbackRate = defaults.object(forKey: Key.playbackRate.rawValue) as? Double ?? 1.0

        let cornerRaw = defaults.string(forKey: Key.miniPlayerDefaultCorner.rawValue) ?? MiniPlayerCorner.bottomRight.rawValue
        self.miniPlayerDefaultCorner = MiniPlayerCorner(rawValue: cornerRaw) ?? .bottomRight
        let themeRaw = defaults.string(forKey: Key.miniPlayerTheme.rawValue) ?? MiniPlayerTheme.minimal.rawValue
        self.miniPlayerTheme = MiniPlayerTheme(rawValue: themeRaw) ?? .minimal
        self.voiceInputEnabled = defaults.object(forKey: Key.voiceInputEnabled.rawValue) as? Bool ?? true
        self.whisperModelID = defaults.string(forKey: Key.whisperModelID.rawValue) ?? WhisperModel.recommended.id
        self.handsFreeEnabled = defaults.bool(forKey: Key.handsFreeEnabled.rawValue)
        self.inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID.rawValue)
        self.yapperKey = YapperKey(rawValue: defaults.string(forKey: Key.yapperKey.rawValue) ?? "") ?? .default
        let storedScale = defaults.object(forKey: Key.cassetteScale.rawValue) as? Double ?? 1.0
        self.cassetteScale = min(max(storedScale, Self.cassetteScaleRange.lowerBound),
                                 Self.cassetteScaleRange.upperBound)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin.rawValue)
        let designRaw = defaults.string(forKey: "settingsDesign") ?? SettingsDesign.systemStyle.rawValue
        self.settingsDesign = SettingsDesign(rawValue: designRaw) ?? .systemStyle
        self.openAIModelID = defaults.string(forKey: Key.openAIModelID.rawValue) ?? OpenAIModel.defaultModel.id
        // Read before any didSet can fire, so the "is this a fresh install" probe above still
        // sees a pristine defaults domain.
        self.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted.rawValue)
    }
}

enum SettingsDesign: String, CaseIterable, Identifiable {
    case systemStyle, minimal
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .systemStyle: "System Settings"
        case .minimal:     "Minimal"
        }
    }
}

enum MiniPlayerTheme: String, CaseIterable, Identifiable {
    case minimal, cassette
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .minimal:  "Minimal"
        case .cassette: "Cassette"
        }
    }
}

enum MiniPlayerCorner: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bottomRight: "Bottom Right"
        case .bottomLeft:  "Bottom Left"
        case .topRight:    "Top Right"
        case .topLeft:     "Top Left"
        }
    }
}

enum ElevenLabsModel: String, CaseIterable, Identifiable {
    case flashV25 = "eleven_flash_v2_5"
    case multilingualV2 = "eleven_multilingual_v2"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .flashV25:        "Flash v2.5 (faster, ~75ms)"
        case .multilingualV2:  "Multilingual v2 (higher fidelity)"
        }
    }
    /// Max input character count per request, per ElevenLabs.
    var characterLimit: Int {
        switch self {
        case .flashV25:        40_000
        case .multilingualV2:  10_000
        }
    }
    static let defaultModel: ElevenLabsModel = .flashV25
}
