import Foundation

/// Writes clock times the way people type them. Whisper hears "four oh one" and writes "401" or
/// "4.01"; this turns those into "4:01" when the sentence makes it a time.
///
/// A bare number is only a time with a reason to think so: a.m./p.m. after it ("401 pm"), or a
/// word in front that people put before times ("at 401", "around 1130", "until 4.15"), or the
/// other end of a range that already is one ("from 11:30 to 1230"). Anything that reads as a
/// quantity, a code or an address stays a number: "401k", "at 401 people", "error 401",
/// "at 401 Main Street". The formatting model isn't used for this on purpose: small models are
/// unreliable with numbers, and its safety check refuses changed words anyway.
enum SpokenTimes {
    /// Words that put a time after them.
    private static let lead = #"at|around|by|until|till|til|from|before|after|since|about|between|starting|ending"#
    /// H then MM, with the forms Whisper writes: "401", "4.01", "4 01", "1130".
    private static let clock = #"(1[0-2]|0?[1-9])[.\s]?([0-5]\d)"#

    private static let withMeridiem = try! NSRegularExpression(
        pattern: #"\b"# + clock + #"\s?([ap]\.?\s?m\b\.?)"#, options: [.caseInsensitive])
    private static let afterLead = try! NSRegularExpression(
        pattern: #"\b((?:"# + lead + #")\s+(?:like\s+|about\s+|around\s+)?)"# + clock + #"\b(?![.:,]?\d)"#,
        options: [.caseInsensitive])
    private static let rangeEnd = try! NSRegularExpression(
        pattern: #"(\b\d{1,2}(?::\d\d)?(?:\s?[ap]\.?\s?m\.?)?\s*(?:to|or|and|-|–|until|till)\s*)"# + clock + #"\b(?![.:,]?\d)"#,
        options: [.caseInsensitive])

    /// A number followed by one of these is a count, not a time.
    private static let quantityWords: Set<String> = [
        "people", "person", "users", "views", "followers", "subscribers", "likes", "comments", "messages",
        "emails", "dollars", "bucks", "cents", "percent", "times", "words", "miles", "kilometers", "km",
        "items", "units", "calories", "rpm", "degrees", "pounds", "lbs", "feet", "steps", "pages", "lines",
        "errors", "points", "votes", "orders", "videos", "posts", "k", "m", "b", "x", "ms", "mb", "gb",
        "kb", "fps", "hz", "px", "pixels", "frames", "seconds", "minutes", "hours", "days", "weeks", "years",
    ]
    private static let streetWords: Set<String> = [
        "street", "st", "avenue", "ave", "road", "rd", "drive", "dr", "boulevard", "blvd", "lane", "ln",
        "way", "court", "ct", "place", "pl", "parkway", "highway", "hwy", "suite", "apt", "unit", "floor",
    ]

    // MARK: Times said in words (Parakeet writes these out)

    private static let hourWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                    "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                                    "eighteen", "nineteen", "twenty", "twenty one", "twenty two", "twenty three"]
    private static let units = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                                "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]

    private static let spokenClock: NSRegularExpression = {
        let hour = hourWords.sorted { $0.count > $1.count }.map { $0.replacingOccurrences(of: " ", with: "[ -]") }.joined(separator: "|")
        let unit = units.joined(separator: "|")
        let minute = #"oh[ -](?:"# + unit + #")|(?:"# + teens.joined(separator: "|") + #")|(?:twenty|thirty|forty|fifty)(?:[ -](?:"# + unit + #"))?"#
        let pattern = #"\b((?:"# + lead + #")\s+(?:like\s+|about\s+|around\s+)?)(?<h>"# + hour + #")[ -](?<m>"# + minute + #")\b"#
            + #"|\b(?<h2>"# + hour + #")[ -](?<m2>"# + minute + #")(?=\s?[ap]\.?\s?m\b)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func value(ofHour words: String) -> Int? {
        let w = words.lowercased().replacingOccurrences(of: "-", with: " ")
        return hourWords.firstIndex(of: w).map { $0 + 1 }
    }

    private static func value(ofMinute words: String) -> Int? {
        let parts = words.lowercased().replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        if parts.first == "oh", parts.count == 2, let u = units.firstIndex(of: parts[1]) { return u + 1 }
        if parts.count == 1, let t = teens.firstIndex(of: parts[0]) { return t + 10 }
        guard let ten = tens[parts[0]] else { return nil }
        if parts.count == 2, let u = units.firstIndex(of: parts[1]) { return ten + u + 1 }
        return parts.count == 1 ? ten : nil
    }

    /// "at four thirty" → "at 4:30", "at twenty one oh four" → "at 21:04", "four fifteen pm" →
    /// "4:15 pm". Same reasons-to-believe as the digit forms: a time word before, or a.m./p.m. after.
    static func normalizeSpoken(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in spokenClock.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hRange = match.range(withName: "h").location != NSNotFound ? match.range(withName: "h") : match.range(withName: "h2")
            let mRange = match.range(withName: "m").location != NSNotFound ? match.range(withName: "m") : match.range(withName: "m2")
            guard let h = value(ofHour: ns.substring(with: hRange)), let m = value(ofMinute: ns.substring(with: mRange)),
                  !looksLikeQuantity(after: match.range.location + match.range.length, in: ns) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: hRange.location - cursor))
            out += String(format: "%d:%02d", h, m)
            cursor = mRange.location + mRange.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func normalize(_ text: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }
        var out = text
        out = replace(withMeridiem, in: out, hour: 1, minute: 2) { match, s in
            let suffix = substring(s, match.range(at: 3))
            return " " + suffix.trimmingCharacters(in: .whitespaces)
        }
        out = replace(afterLead, in: out, hour: 2, minute: 3, prefixGroup: 1)
        out = replace(rangeEnd, in: out, hour: 2, minute: 3, prefixGroup: 1)
        return out
    }

    /// Rewrites each match as `prefix + H:MM + suffix`, skipping ones that read as a quantity.
    private static func replace(_ regex: NSRegularExpression, in text: String, hour: Int, minute: Int,
                                prefixGroup: Int? = nil,
                                suffix: ((NSTextCheckingResult, String) -> String)? = nil) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = match.range.location + match.range.length
            guard !looksLikeQuantity(after: end, in: ns), !isCode(before: match.range.location, in: ns) else { continue }
            let h = Int(substring(text, match.range(at: hour)))!
            let mm = substring(text, match.range(at: minute))
            let prefix = prefixGroup.map { substring(text, match.range(at: $0)) } ?? ""
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += prefix + "\(h):\(mm)" + (suffix?(match, text) ?? "")
            cursor = end
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func substring(_ s: String, _ range: NSRange) -> String {
        guard range.location != NSNotFound else { return "" }
        return (s as NSString).substring(with: range)
    }

    /// The next word or two make the number a count or an address: "at 430 people", "401k",
    /// "at 401 Main Street".
    private static func looksLikeQuantity(after index: Int, in ns: NSString) -> Bool {
        let rest = ns.substring(from: index)
        if let first = rest.first, first.isLetter { return true }   // "401k", "1130am" handled earlier
        if rest.hasPrefix("%") || rest.hasPrefix("$") { return true }
        let next = rest.split(whereSeparator: { $0.isWhitespace }).prefix(3).map {
            $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
        }
        guard let word = next.first else { return false }
        if quantityWords.contains(word) { return true }
        if next.prefix(3).contains(where: { streetWords.contains($0) }) { return true }
        return false
    }

    /// "error 401", "#401", "room 1130", "$401": the number names something.
    private static func isCode(before index: Int, in ns: NSString) -> Bool {
        let head = ns.substring(to: index)
        if head.hasSuffix("$") || head.hasSuffix("#") { return true }
        let last = head.split(whereSeparator: { $0.isWhitespace }).last.map {
            $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
        }
        return ["error", "code", "room", "version", "v", "route", "flight", "page", "apartment", "unit", "number"]
            .contains(last ?? "")
    }
}
