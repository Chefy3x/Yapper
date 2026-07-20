import Foundation

/// One unit of "thing Yapper is reading aloud right now (or read recently)."
/// Used by the mini player for display and by History (Slice 4) for replay.
struct ReadingItem: Identifiable, Hashable {
    let id: UUID
    let sourceApp: String
    let createdAt: Date
    let cleanedText: String
    var rawText: String

    var preview: String {
        let oneLine = cleanedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.count <= 60 { return oneLine }
        return String(oneLine.prefix(60)) + "…"
    }

    static func make(sourceApp: String, cleaned: String, raw: String) -> ReadingItem {
        ReadingItem(id: UUID(),
                    sourceApp: sourceApp,
                    createdAt: Date(),
                    cleanedText: cleaned,
                    rawText: raw)
    }
}
