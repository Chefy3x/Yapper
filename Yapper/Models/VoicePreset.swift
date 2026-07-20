import Foundation

enum TTSProvider: String, Codable, CaseIterable {
    case elevenLabs
    case openAI
    case macOSNative
}

struct VoicePreset: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let provider: TTSProvider
    let providerVoiceID: String
    let language: String
    var isCustom: Bool = false

    static let defaultPreset = VoicePreset(
        id: "rachel",
        displayName: "Rachel",
        provider: .elevenLabs,
        providerVoiceID: "21m00Tcm4TlvDq8ikWAM",
        language: "en"
    )

    static let presets: [VoicePreset] = [
        defaultPreset,
        VoicePreset(id: "chris", displayName: "Chris", provider: .elevenLabs, providerVoiceID: "iP95p4xoKVk53GoZ742B", language: "en"),
        VoicePreset(id: "river", displayName: "River", provider: .elevenLabs, providerVoiceID: "SAz9YHcvj6GT2YYXdXww", language: "en"),
        VoicePreset(id: "adam", displayName: "Adam", provider: .elevenLabs, providerVoiceID: "pNInz6obpgDQGcFmaJgB", language: "en"),
        VoicePreset(id: "bella", displayName: "Bella", provider: .elevenLabs, providerVoiceID: "EXAVITQu4vr4xnSDxMaL", language: "en"),
        VoicePreset(id: "antoni", displayName: "Antoni", provider: .elevenLabs, providerVoiceID: "ErXwobaYiN019PkySvjV", language: "en"),
        VoicePreset(id: "system", displayName: "macOS System", provider: .macOSNative, providerVoiceID: "com.apple.voice.compact.en-US.Samantha", language: "en")
    ]
}
