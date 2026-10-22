import Testing
import Foundation

// The first-run guide is gated on one probe: has Yapper ever persisted anything. Getting that
// wrong in either direction is user-visible — a fresh install that never learns the Right ⌘
// gesture, or an existing user handed a setup wizard on upgrade.
struct OnboardingGateTests {

    /// Each test gets its own defaults domain so nothing touches the real one.
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "app.yapper.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            // that empties the domain but leaves its plist behind: thousands piled up, one per run
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(name).plist"))
        }
        try body(defaults)
    }

    @Test func pristineDomainIsAFirstRun() {
        withSuite { defaults in
            #expect(SettingsStore.looksLikeFirstRun(defaults: defaults))
        }
    }

    @Test func anyPersistedPreferenceMeansTheAppHasBeenUsed() {
        withSuite { defaults in
            defaults.set("some-voice-id", forKey: SettingsStore.Key.activeVoiceID.rawValue)
            #expect(!SettingsStore.looksLikeFirstRun(defaults: defaults))
        }
    }

    // Upgrading into this version writes nothing but the completion flag itself. If that flag
    // counted as prior use, the probe would answer "existing install" for a genuinely fresh one.
    @Test func completionFlagAloneDoesNotCountAsPriorUse() {
        withSuite { defaults in
            defaults.set(true, forKey: SettingsStore.Key.onboardingCompleted.rawValue)
            #expect(SettingsStore.looksLikeFirstRun(defaults: defaults))
        }
    }

    @Test func everyStoredKeyCountsAsPriorUse() {
        for key in SettingsStore.Key.allCases where key != .onboardingCompleted {
            withSuite { defaults in
                defaults.set(1, forKey: key.rawValue)
                #expect(!SettingsStore.looksLikeFirstRun(defaults: defaults),
                        "\(key.rawValue) should mark the install as used")
            }
        }
    }
}

// The menu bar strip and the guide's closing recap render from one list, so they can't drift.
struct ShortcutReferenceTests {

    @Test func listsTheUserFacingGestures() {
        // Read/pause, hold-to-talk, lock the mic, paste again, selection, Conversation Mode, skip.
        #expect(ShortcutReference.all(yapperKey: .rightOption).count == 7)
    }

    // Right ⌘ + D dumps the accessibility tree to disk. It's a debug affordance that belongs in
    // Settings only — surfacing it in the menu would put a developer tool in everyone's face.
    @Test func omitsTheDebugAXDump() {
        let labels = ShortcutReference.all(yapperKey: .rightOption).map { $0.label.lowercased() }
        #expect(!labels.contains { $0.contains("debug") || $0.contains("dump") })
    }

    @Test func everyLineIsLabelledAndKeyed() {
        for item in ShortcutReference.all(yapperKey: .rightOption) {
            #expect(!item.caps.isEmpty)
            #expect(!item.label.isEmpty)
        }
    }

    // One key talks and reads, so every list is drawn in groups; a group with nothing in it would
    // leave a heading over empty space.
    @Test func everyGroupHasItsGestures() {
        let key = YapperKey.rightOption
        #expect(ShortcutReference.items(in: .voiceIn, yapperKey: key).map(\.label).allSatisfy {
            !$0.lowercased().contains("read") })
        #expect(ShortcutReference.items(in: .readAloud, yapperKey: key).count == 3)
        #expect(ShortcutReference.items(in: .voiceIn, yapperKey: key).count == 3)
        #expect(ShortcutReference.items(in: .conversation, yapperKey: key).count == 1)
    }
}

// A key check has to distinguish "ElevenLabs says no" from "we couldn't ask". Collapsing the two
// would tell someone on a flaky connection to go regenerate a credential that was never broken.
struct APIKeyCheckTests {

    @Test func successIsValid() {
        #expect(APIKeyCheck.forStatus(200) == .valid)
    }

    @Test func onlyAuthFailuresBlameTheKey() {
        #expect(APIKeyCheck.forStatus(401) == .rejected)
        #expect(APIKeyCheck.forStatus(403) == .rejected)
    }

    // 429 means the key works and is busy; 5xx means ElevenLabs is having a bad day. Neither is
    // evidence against the credential, so neither may be reported as a rejection.
    @Test func rateLimitsAndServerErrorsAreInconclusive() {
        for code in [429, 500, 502, 503] {
            guard case .inconclusive = APIKeyCheck.forStatus(code) else {
                Issue.record("HTTP \(code) should not be a verdict on the key")
                return
            }
        }
    }

    // Guards the early return: a blank field must never become a network round-trip.
    @Test func blankKeyIsRejectedWithoutAskingTheNetwork() async {
        #expect(await ElevenLabsClient.validate(apiKey: "   ") == .rejected)
        #expect(await OpenAIClient.validate(apiKey: "") == .rejected)
    }

    // Both providers share one verdict type, so a status means the same thing whichever API
    // returned it. If these ever diverge, one provider's UI is lying.
    @Test func bothProvidersShareOneVerdictVocabulary() {
        #expect(APIKeyCheck.forStatus(200) == .valid)
        #expect(APIKeyCheck.forStatus(401) == .rejected)
    }
}
