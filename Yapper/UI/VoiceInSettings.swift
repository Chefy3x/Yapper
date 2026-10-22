import SwiftUI
import AppKit
import AVFoundation

// Settings → Voice in: Setup, Dictations, Dictionary, Snippets, Models. Modelled on Wispr Flow's
// hub, in Yapper's light Settings look (Brand in SettingsTheme.swift). Shared building blocks
// (Card, RowLabel, RowDivider, PrimaryButton) live in SettingsView.swift.

/// The stores these pages edit. Settings passes the app's own; the screenshot probe passes
/// temp stores full of invented data.
@MainActor
struct VoiceInStores {
    let dictations: DictationHistoryStore
    let snippets: SnippetStore
    let vocabulary: VocabularyStore

    static var live: VoiceInStores {
        VoiceInStores(dictations: AppState.shared.dictations, snippets: AppState.shared.snippets,
                      vocabulary: AppState.shared.vocabulary)
    }
}

// MARK: - Small parts

/// A label stuck on a row: In use, Learned, Wispr, Copied.
struct TagChip: View {
    enum Tone { case plain, accent, warning }
    let text: String
    var tone: Tone = .plain

    var body: some View {
        Text(text)
            .settingsFont(size: 10.5, weight: .semibold)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule(style: .continuous).fill(background))
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .accent: Brand.blueDeep
        case .warning: Brand.red
        case .plain: Brand.muted
        }
    }
    private var background: Color {
        switch tone {
        case .accent: Brand.blueSoft
        case .warning: Brand.red.opacity(0.1)
        case .plain: Brand.sunken
        }
    }
}

/// Round icon button for row actions.
struct RowIconButton: View {
    let symbol: String
    let help: String
    var active = false
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .settingsFont(size: 10.5, weight: .semibold)
                .foregroundStyle(active ? Brand.blueDeep : (hovering ? Brand.ink : Brand.muted))
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Brand.ink.opacity(0.08) : Brand.sunken))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Icon in a disc, title and subtitle: the head of each card.
struct CardHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .settingsFont(size: 14, weight: .semibold)
                .foregroundStyle(skin.iconTint)
                .iconTile(skin.iconChipBG, size: 34)
            RowLabel(title, subtitle: subtitle)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
    }
}

/// Search field in the page's voice.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .settingsFont(size: 11.5, weight: .semibold)
                .foregroundStyle(Brand.faint)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .settingsFont(size: 13)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.lineStrong, lineWidth: 1))
    }
}

/// Dashed-outline panel for "nothing here yet".
struct EmptyStateCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .settingsFont(size: 18, weight: .medium)
                .foregroundStyle(Brand.muted)
                .iconTile(Brand.sunken, size: 40)
            Text(title)
                .settingsDisplay(20)
                .foregroundStyle(Brand.ink)
            Text(detail)
                .settingsFont(size: 12)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous).fill(Brand.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
            .strokeBorder(Brand.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Setup

struct VoiceInPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VoiceInSection()
            PillPreviewCard()
        }
    }
}

/// What the recording pill looks like in each state, so the toggle above means something.
private struct PillPreviewCard: View {
    @Environment(\.settingsSkin) private var skin
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(icon: "capsule", title: "The recording pill",
                           subtitle: "Sits just above the Dock while you talk. It never takes a click or the focus, so the words still land where you were.")
                HStack(spacing: 18) {
                    stage("Talking", .listening(locked: false, handsFree: false))
                    stage("Working", .transcribing)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.sunken))
            }
        }
    }

    private func stage(_ label: String, _ phase: RecordingHUDModel.Phase) -> some View {
        VStack(spacing: 10) {
            if settings.pillStyle == .mouth {
                // the pill with the mouth on it, held in one pose
                ZStack(alignment: .bottom) {
                    RecordingPill(phase: phase, motion: PillMotion(fixed: 0.75), style: .mouth)
                    PillMouth(phase: phase, live: nil,
                              still: phase == .transcribing ? MouthStage.thinking(0.6) : .voice(J: 0.55, W: 0.25, T: 0))
                        .padding(.bottom, RecordingPill.height / 2)
                }
                .frame(height: 80, alignment: .bottom)
                .clipped()
            } else {
                RecordingPill(phase: phase, motion: PillMotion(fixed: 0.75, working: phase == .transcribing))
            }
            Text(label)
                .settingsBody(9.5, .semibold)
                .tracking(0.2)
                .foregroundStyle(Brand.faint)
        }
    }
}

// MARK: - Models

struct ModelsPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var formatter: SmartFormatter = AppState.shared.formatter
    @Environment(\.settingsSkin) private var skin
    @State private var sizes: [String: Int64] = [:]
    @State private var formatterBytes: Int64 = 0
    @State private var deleting: WhisperModel?
    @State private var deletingFormatter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(icon: "waveform", title: "Speech to text",
                               subtitle: "Turns what you say into words. Pick one; it downloads once and runs on this Mac. Nothing is uploaded.")
                        .padding(.bottom, 4)
                    ForEach(WhisperModel.catalog) { model in
                        RowDivider()
                        speechRow(model)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(icon: "list.bullet.indent", title: "Formatting",
                               subtitle: "Lays out spoken lists and applies \"3, no wait, 4\" fixes. Only runs when a dictation asks for it.")
                        .padding(.bottom, 4)
                    RowDivider()
                    formatterRow
                }
            }
            storageFooter
        }
        .task(id: refreshKey) { await measure() }
        .confirmationDialog(deleting.map { "Delete \($0.displayName)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let model = deleting { try? model.deleteFiles() }
                deleting = nil
                Task { await measure() }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its files come off this Mac. You can download it again any time.")
        }
        .confirmationDialog("Delete \(FormatterModel.displayName)?", isPresented: $deletingFormatter) {
            Button("Delete", role: .destructive) {
                settings.smartFormattingEnabled = false
                Task { await formatter.deleteModel(); await measure() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lists and \"no wait\" fixes stop until it's downloaded again.")
        }
    }

    /// Re-measure when a download finishes or the model changes.
    private var refreshKey: String { "\(settings.whisperModelID)|\(state.whisperModelStatus)|\(formatter.status)" }

    private func measure() async {
        let folders = WhisperModel.catalog.filter(\.isDownloaded).map { ($0.id, $0.storageFolder) }
        let formatterURL = FormatterModel.fileURL
        let measured = await Task.detached(priority: .utility) { () -> ([String: Int64], Int64) in
            var out: [String: Int64] = [:]
            for (id, folder) in folders { out[id] = WhisperModel.bytesOnDisk(at: folder) }
            let f = (try? FileManager.default.attributesOfItem(atPath: formatterURL.path)[.size] as? Int64) ?? 0
            return (out, f ?? 0)
        }.value
        sizes = measured.0
        formatterBytes = measured.1
    }

    // MARK: Speech rows

    private func speechRow(_ model: WhisperModel) -> some View {
        let active = model.id == settings.whisperModelID
        let downloaded = model.isDownloaded
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: active ? "checkmark.circle.fill" : downloaded ? "circle" : "arrow.down.circle")
                .settingsFont(size: 15, weight: .medium)
                .foregroundStyle(active ? AnyShapeStyle(skin.accent) : AnyShapeStyle(Brand.faint))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).settingsBody(13, .semibold)
                    if active { TagChip(text: "In use", tone: .accent) }
                    if model.id == WhisperModel.recommended.id, !active { TagChip(text: "Recommended") }
                }
                Text(model.blurb)
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta(model, downloaded: downloaded))
                    .settingsBody(10.5, .medium)
                    .foregroundStyle(Brand.faint)
                if active, case .downloading(let p) = state.whisperModelStatus {
                    ProgressView(value: p).tint(skin.controlTint).padding(.top, 2)
                }
            }
            Spacer(minLength: 10)
            speechAction(model, active: active, downloaded: downloaded)
                .padding(.top, 1)
        }
        .contentShape(Rectangle())
    }

    private func meta(_ model: WhisperModel, downloaded: Bool) -> String {
        let engine = model.engine == .parakeet ? "Parakeet · Neural Engine" : "Whisper · Core ML"
        if downloaded, let bytes = sizes[model.id], bytes > 0 { return "\(engine) · \(byteString(bytes)) on disk" }
        return "\(engine) · \(model.approxSize.replacingOccurrences(of: "≈ ", with: "")) download"
    }

    @ViewBuilder
    private func speechAction(_ model: WhisperModel, active: Bool, downloaded: Bool) -> some View {
        let busy = state.whisperModelStatus.isBusy
        if active {
            switch state.whisperModelStatus {
            case .downloading(let p):
                Text("\(Int(p * 100))%").settingsBody(11, .semibold).monospacedDigit().foregroundStyle(Brand.muted)
            case .loading:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading").settingsBody(11).foregroundStyle(Brand.muted) }
            case .notDownloaded:
                Button("Download") { state.voiceInput.downloadModel() }.controlSize(.small)
            case .failed:
                Button("Retry") { state.voiceInput.downloadModel() }.controlSize(.small)
            case .ready:
                Text("Ready").settingsBody(10.5, .semibold).tracking(0)
                    .foregroundStyle(skin.okTint)
            case .downloaded:
                Text("Loads when Voice in is on").settingsBody(10.5).foregroundStyle(Brand.faint)
            }
        } else if downloaded {
            HStack(spacing: 6) {
                Button("Use") { settings.whisperModelID = model.id }
                    .controlSize(.small)
                    .disabled(busy)
                RowIconButton(symbol: "trash", help: "Delete \(model.displayName)", role: .destructive) { deleting = model }
            }
        } else {
            Button("Download") {
                settings.whisperModelID = model.id
                state.voiceInput.downloadModel()
            }
            .controlSize(.small)
            .disabled(busy)
            .help("Downloads \(model.displayName) and switches to it")
        }
    }

    // MARK: Formatter row

    private var formatterRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: formatter.status == .ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .settingsFont(size: 15, weight: .medium)
                .foregroundStyle(formatter.status == .ready && settings.smartFormattingEnabled
                                 ? AnyShapeStyle(skin.accent) : AnyShapeStyle(Brand.faint))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(FormatterModel.displayName).settingsBody(13, .semibold)
                    if formatter.status == .ready, settings.smartFormattingEnabled { TagChip(text: "In use", tone: .accent) }
                }
                Text("Qwen's small open model (Apache-2.0), 4-bit, through llama.cpp on the GPU. Loads as you start talking and unloads after five idle minutes.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(formatter.status == .ready && formatterBytes > 0
                     ? "llama.cpp · Metal · \(byteString(formatterBytes)) on disk"
                     : "llama.cpp · Metal · \(FormatterModel.approxSize) download")
                    .settingsBody(10.5, .medium)
                    .foregroundStyle(Brand.faint)
                if case .downloading(let p) = formatter.status {
                    ProgressView(value: p).tint(skin.controlTint).padding(.top, 2)
                }
                if case .failed(let why) = formatter.status {
                    Text(why).settingsBody(10.5).foregroundStyle(skin.destructive)
                }
            }
            Spacer(minLength: 10)
            formatterAction.padding(.top, 1)
        }
    }

    @ViewBuilder
    private var formatterAction: some View {
        switch formatter.status {
        case .unsupported:
            Text("Needs Apple Silicon").settingsBody(10.5).foregroundStyle(Brand.faint)
        case .notDownloaded, .failed:
            Button("Download") {
                formatter.download()
                settings.smartFormattingEnabled = true
            }
            .controlSize(.small)
        case .downloading(let p):
            Text("\(Int(p * 100))%").settingsBody(11, .semibold).monospacedDigit().foregroundStyle(Brand.muted)
        case .verifying:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking").settingsBody(11).foregroundStyle(Brand.muted) }
        case .ready:
            HStack(spacing: 8) {
                Toggle("", isOn: $settings.smartFormattingEnabled)
                    .labelsHidden()
                    .toggleStyle(.ink)
                    .controlSize(.small)
                    .tint(skin.controlTint)
                RowIconButton(symbol: "trash", help: "Delete \(FormatterModel.displayName)", role: .destructive) { deletingFormatter = true }
            }
        }
    }

    private var storageFooter: some View {
        let total = sizes.values.reduce(0, +) + formatterBytes
        return HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .settingsFont(size: 11, weight: .semibold)
                .foregroundStyle(Brand.faint)
            Text(total > 0 ? "\(byteString(total)) of models on this Mac, in Application Support › Yapper."
                           : "Models are kept in Application Support › Yapper.")
                .settingsBody(11)
                .foregroundStyle(Brand.muted)
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([DictationHistoryStore.defaultDirectory()])
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Dictations

/// Plays a kept recording. One at a time.
@MainActor
final class DictationPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(_ id: UUID, url: URL?) {
        if playingID == id { stop(); return }
        stop()
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        player = p
        playingID = id
        p.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct DictationsPanel: View {
    @ObservedObject var store: DictationHistoryStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin
    @StateObject private var player = DictationPlayer()
    @State private var query = ""
    @State private var expanded: UUID?
    @State private var limit = 150
    @State private var confirmingClear = false
    @State private var working: Set<UUID> = []
    @State private var notes: [UUID: String] = [:]

    init(store: DictationHistoryStore = AppState.shared.dictations) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            statsCard
            if store.entries.isEmpty {
                EmptyStateCard(icon: "text.bubble",
                               title: settings.dictationRetention == .never ? "Not keeping dictations" : "Nothing dictated yet",
                               detail: settings.dictationRetention == .never
                                ? "Pick how long to keep them above, and what you say from then on shows up here."
                                : "Hold \(settings.yapperKey.keycap) and talk. What you said, where it went, and the recording show up here.")
            } else {
                SearchField(prompt: "Search what you've said", text: $query)
                list
            }
        }
        .onChange(of: settings.dictationRetention) { store.prune(retention: $0) }
        .onDisappear { player.stop() }
    }

    // MARK: Stats + retention

    private var statsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    stat(store.totalWords.formatted(), "words")
                    stat(store.entries.count.formatted(), store.entries.count == 1 ? "dictation" : "dictations")
                    if let wpm = wordsPerMinute { stat("\(wpm)", "words a minute") }
                    Spacer()
                }
                .padding(.bottom, 6)
                RowDivider()
                HStack(spacing: 12) {
                    RowLabel("Keep dictations", subtitle: "Older ones are deleted for good. Nothing ever leaves this Mac.")
                    Spacer()
                    Picker("", selection: $settings.dictationRetention) {
                        ForEach(DictationRetention.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                RowDivider()
                HStack(spacing: 12) {
                    RowLabel("Keep recordings", subtitle: "So you can play one back or transcribe it again. Recordings go after a week at most.")
                    Spacer()
                    Toggle("", isOn: $settings.keepDictationAudio)
                        .labelsHidden()
                        .toggleStyle(.ink)
                        .tint(skin.controlTint)
                        .disabled(settings.dictationRetention == .never)
                }
                if !store.entries.isEmpty {
                    RowDivider()
                    HStack(spacing: 12) {
                        RowLabel("Clear dictations", subtitle: "Deletes every dictation and recording now.")
                        Spacer()
                        Button("Clear…", role: .destructive) { confirmingClear = true }
                            .controlSize(.small)
                            .confirmationDialog("Delete every dictation?", isPresented: $confirmingClear) {
                                Button("Delete all", role: .destructive) { player.stop(); store.clearAll() }
                                Button("Cancel", role: .cancel) {}
                            } message: { Text("The text and the recordings both go. This can't be undone.") }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .settingsDisplay(34)
                .monospacedDigit()
                .foregroundStyle(AnyShapeStyle(Brand.ink))
            Text(label)
                .settingsBody(10, .semibold)
                .tracking(0.2)
                .foregroundStyle(Brand.muted)
        }
    }

    /// Speaking pace across what was typed, from the recordings' length.
    private var wordsPerMinute: Int? {
        let typed = store.entries.filter { $0.outcome == .pasted || $0.outcome == .copied }
        let minutes = typed.reduce(0) { $0 + $1.duration } / 60
        guard minutes > 0.2 else { return nil }
        return Int((Double(typed.reduce(0) { $0 + $1.wordCount }) / minutes).rounded())
    }

    // MARK: List

    private var filtered: [Dictation] { store.search(query) }

    private var list: some View {
        let all = filtered
        let shown = Array(all.prefix(limit))
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.at) }
            .sorted { $0.key > $1.key }
        return LazyVStack(alignment: .leading, spacing: 6) {
            if all.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .settingsBody(12)
                    .foregroundStyle(Brand.faint)
                    .padding(.vertical, 20)
            }
            ForEach(days, id: \.key) { day, entries in
                Text(dayLabel(day))
                    .settingsBody(10, .bold)
                    .tracking(1.6)
                    .foregroundStyle(Brand.muted)
                    .padding(.top, day == days.first?.key ? 0 : 14)
                    .padding(.bottom, 4)
                ForEach(entries) { entry in
                    DictationRow(entry: entry,
                                 expanded: expanded == entry.id,
                                 hasAudio: store.audioURL(for: entry) != nil,
                                 playing: player.playingID == entry.id,
                                 working: working.contains(entry.id),
                                 note: notes[entry.id],
                                 onToggle: { withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == entry.id ? nil : entry.id } },
                                 onCopy: { copy(entry.text) },
                                 onPaste: { state.pasteDictation(entry.text) },
                                 onPlay: { player.toggle(entry.id, url: store.audioURL(for: entry)) },
                                 onRetranscribe: { retranscribe(entry) },
                                 onDelete: {
                                     if player.playingID == entry.id { player.stop() }
                                     store.remove(entry.id)
                                 })
                }
            }
            if all.count > shown.count {
                Button("Show \(min(150, all.count - shown.count)) more") { limit += 150 }
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "TODAY" }
        if cal.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func retranscribe(_ entry: Dictation) {
        working.insert(entry.id)
        notes[entry.id] = nil
        Task {
            let error = await state.retranscribe(entry)
            working.remove(entry.id)
            notes[entry.id] = error
        }
    }
}

private struct DictationRow: View {
    let entry: Dictation
    let expanded: Bool
    let hasAudio: Bool
    let playing: Bool
    let working: Bool
    let note: String?
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onPlay: () -> Void
    let onRetranscribe: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(entry.at.formatted(date: .omitted, time: .shortened))
                    .settingsBody(11, .medium)
                    .monospacedDigit()
                    .foregroundStyle(Brand.faint)
                    .frame(width: 58, alignment: .leading)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    if entry.text.isEmpty {
                        Text(entry.outcome == .failed ? "Couldn't transcribe this one" : "Nothing to type: silence, or just “um”")
                            .settingsBody(13)
                            .italic()
                            .foregroundStyle(Brand.faint)
                    } else {
                        Text(entry.text)
                            .settingsBody(13)
                            .foregroundStyle(Brand.ink)
                            .lineLimit(expanded ? nil : 2)
                            .textSelection(.enabled)
                    }
                    meta
                }
                Spacer(minLength: 8)
                actions
                    .opacity(hovering || expanded || playing || working ? 1 : 0)
            }
            if expanded { detail }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Brand.surface)
            .shadow(color: Brand.ink.opacity(hovering || expanded ? 0.07 : 0.03), radius: hovering || expanded ? 5 : 1, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(expanded ? Brand.lineStrong : Brand.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if let app = entry.appName {
                Text(app).settingsBody(10.5, .medium).foregroundStyle(Brand.muted)
                dot
            }
            Text(duration).settingsBody(10.5).foregroundStyle(Brand.faint)
            if entry.wordCount > 0 {
                dot
                Text("\(entry.wordCount) word\(entry.wordCount == 1 ? "" : "s")").settingsBody(10.5).foregroundStyle(Brand.faint)
            }
            switch entry.outcome {
            case .copied: TagChip(text: "Not pasted")
            case .empty: TagChip(text: "Empty")
            case .failed: TagChip(text: "Failed", tone: .warning)
            case .retried: TagChip(text: "Transcribed again")
            case .pasted: EmptyView()
            }
            if entry.wasCleaned, entry.outcome != .empty { TagChip(text: "Cleaned up") }
            if working { ProgressView().controlSize(.mini) }
            if let note { Text(note).settingsBody(10.5).foregroundStyle(skin.destructive).lineLimit(1) }
        }
    }

    private var dot: some View { Text("·").settingsBody(10.5).foregroundStyle(Brand.faint) }

    private var duration: String {
        let s = Int(entry.duration.rounded())
        return s < 60 ? "\(max(1, s))s" : "\(s / 60)m \(s % 60)s"
    }

    private var actions: some View {
        HStack(spacing: 5) {
            if !entry.text.isEmpty {
                RowIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy", active: copied) {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                }
                RowIconButton(symbol: "arrow.uturn.left", help: "Paste again where you were", action: onPaste)
            }
            if hasAudio {
                RowIconButton(symbol: playing ? "stop.fill" : "play.fill", help: playing ? "Stop" : "Play the recording",
                              active: playing, action: onPlay)
            }
            Menu {
                if hasAudio { Button("Transcribe again", action: onRetranscribe) }
                if !entry.text.isEmpty { Button("Copy", action: onCopy) }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .settingsFont(size: 11, weight: .bold)
                    .foregroundStyle(Brand.muted)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Brand.ink.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// What the speech model heard next to what was typed, so cleanup is visible.
    private var detail: some View {
        HStack(alignment: .top, spacing: 12) {
            column("Heard", entry.heard.isEmpty ? "—" : entry.heard, dim: true)
            column("Typed", entry.text.isEmpty ? "—" : entry.text, dim: false)
        }
        .padding(.leading, 70)
    }

    private func column(_ title: String, _ text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .settingsBody(9, .bold)
                .tracking(1.4)
                .foregroundStyle(Brand.faint)
            Text(text)
                .settingsFont(size: 11.5, design: .monospaced)
                .foregroundStyle(dim ? AnyShapeStyle(Brand.muted) : AnyShapeStyle(Brand.ink))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(0.04)))
    }
}

// MARK: - Dictionary

struct DictionaryPanel: View {
    @ObservedObject var vocab: VocabularyStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", words = "Words", corrections = "Corrections", learned = "Added by Yapper"
        var id: String { rawValue }
    }

    private enum Entry: Identifiable {
        case term(String, VocabOrigin)
        case rule(Replacement)
        var id: String {
            switch self {
            case .term(let t, _): "t:" + t.lowercased()
            case .rule(let r): "r:" + r.id.uuidString
            }
        }
        var origin: VocabOrigin {
            switch self {
            case .term(_, let o): o
            case .rule(let r): r.origin ?? .manual
            }
        }
        var searchText: String {
            switch self {
            case .term(let t, _): t
            case .rule(let r): r.heard + " " + r.typed
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var addingCorrection = false
    @State private var newWord = ""
    @State private var newHeard = ""
    @State private var newTyped = ""
    @State private var importNote: String?
    @State private var correction = ""
    @State private var learnedNote: String?

    init(vocab: VocabularyStore = AppState.shared.vocabulary) {
        _vocab = ObservedObject(wrappedValue: vocab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let batch = vocab.recentlyLearned { learnedBanner(batch) }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(icon: "character.book.closed.fill", title: "Your words",
                               subtitle: "Names and jargon Yapper should expect, and fixes for what the speech model still gets wrong.",
                               trailing: AnyView(Text(countLine).settingsBody(10.5, .medium).foregroundStyle(Brand.faint)))
                        .padding(.bottom, 4)
                    RowDivider()
                    addBar
                    RowDivider()
                    filterBar
                    list.padding(.top, 10)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    toggleRow(icon: "pencil.and.outline", title: "Learn from your edits",
                              detail: "After Yapper types, it watches that field for a minute. A name you fix by hand is added here, marked as added by Yapper.",
                              isOn: $settings.learnFromEdits)
                    RowDivider()
                    toggleRow(icon: "text.viewfinder", title: "Use words on screen",
                              detail: "Names in the window you're dictating into fix near-miss spellings. Read on this Mac, never kept.",
                              isOn: $settings.useScreenWords)
                    RowDivider()
                    toggleRow(icon: "chevron.left.forwardslash.chevron.right", title: "Code names and @ files",
                              detail: "In editors, terminals and AI chats, say \"user id\" and get userId, or \"at app state dot swift\" and get @AppState.swift. Uses the names in the window; read on this Mac, never kept.",
                              isOn: $settings.codeWords)
                    if WisprFlowImport.isAvailable {
                        RowDivider()
                        wisprImportRow
                    }
                }
            }
            Card { lastTranscriptBlock }
        }
    }

    private var countLine: String {
        "\(vocab.terms.count) word\(vocab.terms.count == 1 ? "" : "s") · \(vocab.replacements.count) fix\(vocab.replacements.count == 1 ? "" : "es")"
    }

    // MARK: Add

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $addingCorrection) {
                Text("Add a word").tag(false)
                Text("Add a correction").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            if addingCorrection {
                HStack(spacing: 8) {
                    TextField("When it hears…", text: $newHeard).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").settingsFont(size: 10, weight: .bold).foregroundStyle(Brand.faint)
                    TextField("…type this", text: $newTyped).textFieldStyle(.roundedBorder).onSubmit(addCorrection)
                    Button("Add", action: addCorrection)
                        .controlSize(.small)
                        .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty || newTyped.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("A name, product or term, spelled your way", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .controlSize(.small)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addWord() { vocab.addTerm(newWord); newWord = "" }
    private func addCorrection() { vocab.addReplacement(heard: newHeard, typed: newTyped); newHeard = ""; newTyped = "" }

    // MARK: List

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Filter.allCases) { f in
                    Button { filter = f } label: {
                        Text(f.rawValue)
                            .settingsFont(size: 11.5, weight: filter == f ? .semibold : .medium)
                            .foregroundStyle(filter == f ? Brand.ink : Brand.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule(style: .continuous)
                                .fill(filter == f ? Brand.surface : .clear)
                                .shadow(color: Brand.ink.opacity(filter == f ? 0.1 : 0), radius: 1.5, y: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule(style: .continuous).fill(Brand.sunken))
            Spacer()
            SearchField(prompt: "Search", text: $query).frame(width: 170)
        }
    }

    private var entries: [Entry] {
        let terms: [Entry] = vocab.terms.reversed().map { .term($0, vocab.origin(ofTerm: $0)) }
        let rules: [Entry] = vocab.replacements.reversed().map { .rule($0) }
        let all: [Entry]
        switch filter {
        case .all: all = rules + terms
        case .words: all = terms
        case .corrections: all = rules
        case .learned: all = (rules + terms).filter { $0.origin != .manual }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.searchText.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    @ViewBuilder
    private var list: some View {
        let items = entries
        if items.isEmpty {
            Text(vocab.terms.isEmpty && vocab.replacements.isEmpty
                 ? "Nothing yet. Add a word above, or let Yapper learn from your edits."
                 : "Nothing matches.")
                .settingsBody(11.5)
                .foregroundStyle(Brand.faint)
                .padding(.vertical, 12)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle().fill(Brand.line).frame(height: 1)
                    }
                    DictionaryRow(content: { rowContent(item) }, origin: item.origin) { remove(item) }
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ item: Entry) -> some View {
        switch item {
        case .term(let t, _):
            Text(t).settingsBody(12.5, .semibold)
        case .rule(let r):
            HStack(spacing: 8) {
                Text(r.heard).settingsBody(12.5).foregroundStyle(Brand.muted).strikethrough(color: .secondary.opacity(0.5))
                Image(systemName: "arrow.right").settingsFont(size: 9, weight: .bold).foregroundStyle(Brand.faint)
                Text(r.typed).settingsBody(12.5, .semibold)
            }
        }
    }

    private func remove(_ item: Entry) {
        switch item {
        case .term(let t, _): vocab.removeTerm(t)
        case .rule(let r): vocab.removeReplacement(r.id)
        }
    }

    // MARK: Learned banner

    private func learnedBanner(_ batch: LearnedBatch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .settingsFont(size: 12, weight: .semibold)
                .foregroundStyle(skin.accent)
            Text("Learned \(batch.words.map { "“\($0)”" }.joined(separator: ", ")) from your edit.")
                .settingsBody(12)
                .lineLimit(2)
            Spacer()
            Button("Undo") { vocab.undoLearned() }.controlSize(.small)
            Button { vocab.dismissLearned() } label: { Image(systemName: "xmark").settingsFont(size: 9, weight: .bold) }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(skin.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(skin.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: Toggles + import

    private func toggleRow(icon: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).settingsBody(13, .semibold)
                Text(detail).settingsBody(11).foregroundStyle(Brand.muted)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.ink)
                .tint(skin.controlTint)
        }
    }

    private var wisprImportRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Wispr Flow").settingsBody(13, .semibold)
                Text(importNote ?? "Brings in the words and corrections Wispr Flow has learned, marked as imported.")
                    .settingsBody(11)
                    .foregroundStyle(importNote == nil ? Brand.muted : Brand.blueDeep)
            }
            Spacer()
            Button("Import", action: importWispr).controlSize(.small)
        }
    }

    private func importWispr() {
        do {
            let entries = try WisprFlowImport.readEntries()
            let plan = WisprFlowImport.plan(entries) { WordKnowledge.isDictionaryWord($0) }
            let added = vocab.merge(terms: plan.terms, rules: plan.rules)
            if added.terms == 0, added.rules == 0 {
                importNote = "Nothing new: Yapper already has every word Wispr Flow knows."
            } else {
                var parts = ["\(added.terms) word\(added.terms == 1 ? "" : "s")"]
                if added.rules > 0 { parts.append("\(added.rules) correction\(added.rules == 1 ? "" : "s")") }
                importNote = "Imported " + parts.joined(separator: " and ") + "."
            }
            Log.voice.info("Wispr Flow import: \(added.terms, privacy: .public) terms, \(added.rules, privacy: .public) rules, \(plan.skippedSnippets, privacy: .public) snippets skipped")
        } catch {
            importNote = error.localizedDescription
        }
    }

    // MARK: Last transcript

    private var lastTranscriptBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "text.cursor", title: "Fix the last dictation",
                       subtitle: "Edit what Yapper typed into what you meant, then save. Every changed word becomes a correction.")
            if let last = vocab.lastTranscript {
                TextEditor(text: $correction)
                    .settingsBody(12)
                    .frame(minHeight: 54, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Brand.ink.opacity(0.05)))
                    .onAppear { correction = last.delivered }
                    .onChange(of: last.delivered) { correction = $0 }
                HStack {
                    (Text(last.at, style: .relative) + Text(" ago"))
                        .settingsBody(11).foregroundStyle(Brand.faint)
                    Spacer()
                    if let learnedNote { Text(learnedNote).settingsBody(11).foregroundStyle(Brand.blueDeep) }
                    Button("Save correction") {
                        let learned = vocab.learn(corrected: correction)
                        learnedNote = learned.isEmpty ? "No word changes to learn"
                            : "Learned \(learned.count) fix\(learned.count == 1 ? "" : "es")"
                    }
                    .controlSize(.small)
                    .disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines) == last.delivered)
                }
            } else {
                Text("Nothing dictated yet.").settingsBody(11).foregroundStyle(Brand.faint)
            }
        }
    }
}

private struct DictionaryRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let origin: VocabOrigin
    let onDelete: () -> Void
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(spacing: 10) {
            content()
            switch origin {
            case .learned:
                HStack(spacing: 3) {
                    Image(systemName: "sparkle").settingsFont(size: 8, weight: .bold)
                        .foregroundStyle(skin.accent)
                    TagChip(text: "Learned")
                }
            case .imported: TagChip(text: "Wispr")
            case .manual: EmptyView()
            }
            Spacer()
            RowIconButton(symbol: "xmark", help: "Remove", role: .destructive, action: onDelete)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Snippets

struct SnippetsPanel: View {
    @ObservedObject var store: SnippetStore
    @Environment(\.settingsSkin) private var skin
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var error: String?
    @State private var editing: UUID?
    @State private var editTrigger = ""
    @State private var editExpansion = ""
    @State private var editError: String?
    @State private var query = ""

    init(store: SnippetStore = AppState.shared.snippets) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeader(icon: "text.badge.plus", title: "New snippet",
                               subtitle: "Say the trigger in any dictation and Yapper types the text instead. Say only the trigger and you get exactly the text.")
                    editor(trigger: $trigger, expansion: $expansion)
                    HStack {
                        if let error { Text(error).settingsBody(11).foregroundStyle(skin.destructive) }
                        Spacer()
                        PrimaryButton(title: "Add snippet", systemImage: "plus", action: add)
                    }
                }
            }
            if store.snippets.isEmpty {
                EmptyStateCard(icon: "text.quote", title: "No snippets yet",
                               detail: "Good ones are things you type often and hate typing: “my calendar link”, “my address”, “standup template”, “sign off”.")
            } else {
                HStack {
                    Text("\(store.snippets.count) snippet\(store.snippets.count == 1 ? "" : "s")")
                        .settingsBody(10, .bold)
                        .tracking(1.6)
                        .foregroundStyle(Brand.muted)
                    Spacer()
                    if store.snippets.count > 6 { SearchField(prompt: "Search", text: $query).frame(width: 180) }
                }
                LazyVStack(spacing: 8) {
                    ForEach(shown) { snippet in
                        if editing == snippet.id { editRow(snippet) } else {
                            SnippetRow(snippet: snippet,
                                       onEdit: { begin(snippet) },
                                       onDelete: { store.remove(snippet.id) })
                        }
                    }
                }
            }
        }
    }

    private var shown: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.trigger.range(of: q, options: .caseInsensitive) != nil || $0.expansion.range(of: q, options: .caseInsensitive) != nil
        }
    }

    private func editor(trigger: Binding<String>, expansion: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("When you say")
                TextField("my calendar link", text: trigger)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 190)
            Image(systemName: "arrow.right")
                .settingsFont(size: 10, weight: .bold)
                .foregroundStyle(Brand.faint)
                .padding(.top, 27)
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Type")
                TextEditor(text: expansion)
                    .settingsFont(size: 12, design: .monospaced)
                    .scrollContentBackground(.hidden)
                    .frame(height: 62)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Brand.ink.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.ink.opacity(0.1), lineWidth: 1))
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .settingsBody(9, .bold)
            .tracking(1.4)
            .foregroundStyle(Brand.faint)
    }

    private func add() {
        do {
            try store.add(trigger: trigger, expansion: expansion)
            trigger = ""; expansion = ""; error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func begin(_ s: Snippet) {
        editing = s.id
        editTrigger = s.trigger
        editExpansion = s.expansion
        editError = nil
    }

    private func editRow(_ s: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            editor(trigger: $editTrigger, expansion: $editExpansion)
            HStack {
                if let editError { Text(editError).settingsBody(11).foregroundStyle(skin.destructive) }
                Spacer()
                Button("Cancel") { editing = nil }.controlSize(.small)
                Button("Save") {
                    do {
                        try store.update(s.id, trigger: editTrigger, expansion: editExpansion)
                        editing = nil
                    } catch {
                        editError = error.localizedDescription
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.ink.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.blueDeep.opacity(0.35), lineWidth: 1))
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(snippet.trigger)”")
                    .settingsBody(12.5, .semibold)
                if snippet.uses > 0 {
                    Text("used \(snippet.uses)×")
                        .settingsBody(10)
                        .foregroundStyle(Brand.faint)
                }
            }
            .frame(width: 190, alignment: .leading)
            Image(systemName: "arrow.right")
                .settingsFont(size: 9, weight: .bold)
                .foregroundStyle(Brand.faint)
                .padding(.top, 4)
            Text(snippet.expansion)
                .settingsFont(size: 11.5, design: .monospaced)
                .foregroundStyle(Brand.muted)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                RowIconButton(symbol: "pencil", help: "Edit", action: onEdit)
                RowIconButton(symbol: "trash", help: "Delete", role: .destructive, action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Brand.surface)
            .shadow(color: Brand.ink.opacity(hovering ? 0.07 : 0.03), radius: hovering ? 5 : 1, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onHover { hovering = $0 }
    }
}
