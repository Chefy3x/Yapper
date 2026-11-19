import Foundation

/// Writes the numbers Parakeet spells out the way people type them. Parakeet hears "forty-eight
/// hours" and writes the words; this makes it "48 hours".
///
/// The rules, all on the words as spoken (nothing is guessed from a model):
/// - Ten and up become digits: "thirteen" → 13, "forty-eight" → 48, "twenty five hundred" → 2500,
///   "a hundred" → 100, "three point six four" → 3.64, "twentieth" → 20th.
/// - One to nine stay words ("one more thing", "the second one"), unless a unit makes them a
///   figure: "five percent" → 5%, "five dollars" → $5, "eight gigabytes" → 8 gigabytes.
/// - Three or more single digits in a row are a code: "three zero two" → 302.
/// - Years: "twenty nineteen" → 2019, "nineteen ninety" → 1990.
/// - Clock times in a range: "nine thirty to two thirty" → 9:30 to 2:30. Other spoken times
///   are written by `SpokenTimes` first.
/// - Both ends of a range match: "from ten to four" → 10 to 4.
/// - Numbers said side by side that don't make one number stay as said: "three five",
///   "six fifty five boxes", "one on one". So does every other word: "and", "a", "at
///   sign" are never dropped or turned into symbols.
enum SpokenNumbers {
    static let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                        "eight": 8, "nine": 9]
    static let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                       "eighty": 80, "ninety": 90]
    static let scales = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    /// Ordinal words and the cardinal each stands for.
    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90, "hundredth": 100, "thousandth": 1_000,
    ]
    /// Words after a number that make even a small one a figure.
    private static let figureUnits: Set<String> = [
        "gigabytes", "gigabyte", "megabytes", "megabyte", "terabytes", "terabyte", "kilobytes", "gb", "mb", "tb",
        "kb", "gigs", "gig", "k", "x", "am", "pm", "a.m", "p.m",
    ]
    private static let rangeWords: Set<String> = ["to", "or", "through", "till", "until", "-", "–"]

    // MARK: Tokens

    private struct Word {
        var core: String      // lowercased, punctuation stripped
        var lead: String
        var trail: String
        var orig: Int         // index of the space-separated token it came from
        var key: String { core }
    }

    private static func parts(_ token: String) -> (lead: String, core: String, trail: String) {
        let chars = Array(token)
        var s = 0, e = chars.count
        while s < e, !(chars[s].isLetter || chars[s].isNumber) { s += 1 }
        while e > s, !(chars[e - 1].isLetter || chars[e - 1].isNumber) { e -= 1 }
        return (String(chars[..<s]), String(chars[s..<e]), String(chars[e...]))
    }

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || scales[w] != nil || ordinals[w] != nil
    }

    /// Space-separated tokens, with "forty-eight" split into its number words.
    private static func words(_ tokens: [String]) -> [Word] {
        var out: [Word] = []
        for (i, token) in tokens.enumerated() {
            let p = parts(token)
            let lower = p.core.lowercased()
            let pieces = lower.split(separator: "-").map(String.init)
            if pieces.count > 1, pieces.allSatisfy(isNumberWord) {
                for (j, piece) in pieces.enumerated() {
                    out.append(Word(core: piece, lead: j == 0 ? p.lead : "", trail: j == pieces.count - 1 ? p.trail : "", orig: i))
                }
            } else {
                out.append(Word(core: lower, lead: p.lead, trail: p.trail, orig: i))
            }
        }
        return out
    }

    // MARK: Parsing one number

    private enum Kind { case none, unit, teen, tens, hundred, big, and }

    private struct Parsed {
        var value: Int
        var count: Int        // words used
        var ordinal = false
        var hasScale = false
        var singleSmall: Bool { count == 1 && value < 10 }
    }

    /// The longest run from `start` that reads as one number in English grammar.
    private static func parse(_ w: [Word], from start: Int) -> Parsed? {
        var total = 0, chunk = 0, kind = Kind.none, lastBig = Int.max
        var best: Parsed?
        var i = start
        var hasScale = false
        // A bare "hundred" right after digits ("300 hundred") is the model hearing one number twice.
        if scales[w[start].key] != nil, start > 0, !w[start - 1].core.isEmpty, w[start - 1].core.allSatisfy(\.isNumber) { return nil }
        func record(ordinal: Bool = false) {
            best = Parsed(value: total + chunk, count: i - start + 1, ordinal: ordinal, hasScale: hasScale)
        }
        while i < w.count {
            let word = w[i].key
            // A word with a lead mark ("(five") starts something new; one with a trail mark ends here.
            if i > start, !w[i].lead.isEmpty { break }
            if word == "a", i == start, i + 1 < w.count, scales[w[i + 1].key] != nil, w[i].trail.isEmpty {
                chunk = 1; kind = .unit
            } else if let u = units[word] {
                guard kind == .none || kind == .hundred || kind == .big || kind == .and || (kind == .tens && chunk % 10 == 0) else { break }
                if kind == .unit || kind == .teen { break }
                chunk += u; kind = .unit; record()
            } else if let t = teens[word] {
                guard [.none, .hundred, .big, .and].contains(kind), chunk % 100 == 0 else { break }
                chunk += t; kind = .teen; record()
            } else if let t = tens[word] {
                guard [.none, .hundred, .big, .and].contains(kind), chunk % 100 == 0 else { break }
                chunk += t; kind = .tens; record()
            } else if word == "hundred" {
                if kind == .none { chunk = 1 } else { guard [.unit, .teen, .tens].contains(kind), chunk > 0, chunk < 100 else { break } }
                chunk *= 100; kind = .hundred; hasScale = true; record()
            } else if let s = scales[word] {
                if kind == .none { chunk = 1 }
                guard chunk > 0, s < lastBig, kind != .and else { break }
                total += chunk * s; chunk = 0; lastBig = s; kind = .big; hasScale = true; record()
            } else if word == "and" {
                guard kind == .hundred || kind == .big, i + 1 < w.count,
                      units[w[i + 1].key] != nil || teens[w[i + 1].key] != nil || tens[w[i + 1].key] != nil
                else { break }
                kind = .and
            } else if let o = ordinals[word] {
                // An ordinal ends the number: "twenty first", "the first", "hundredth".
                if o >= 100 {
                    if kind == .none { chunk = 1 } else { guard [.unit, .teen, .tens].contains(kind) else { break } }
                    chunk *= o
                } else if o < 10 {
                    guard kind == .none || kind == .hundred || kind == .big || kind == .and || (kind == .tens && chunk % 10 == 0),
                          kind != .unit, kind != .teen else { break }
                    chunk += o
                } else {
                    guard [.none, .hundred, .big, .and].contains(kind), chunk % 100 == 0 else { break }
                    chunk += o
                }
                record(ordinal: true)
                break
            } else {
                break
            }
            if !w[i].trail.isEmpty { break }
            i += 1
        }
        return best
    }

    // MARK: Segments

    private struct Segment {
        var start: Int
        var end: Int          // exclusive, in words
        var text: String?     // nil: keep the words as said
        var smallValue: Int?  // a lone one-to-nine kept as a word, which a range can still turn into a digit
    }

    static func write(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let w = words(tokens)
        guard w.contains(where: { isNumberWord($0.key) || $0.key == "a" }) else { return text }
        var segments: [Segment] = []
        var i = 0
        while i < w.count {
            if let s = timeRange(w, at: i) ?? digitRun(w, at: i) ?? year(w, at: i) ?? number(w, at: i) {
                segments.append(s)
                i = s.end
            } else {
                i += 1
            }
        }
        matchRanges(&segments, w)
        return render(tokens, w, segments)
    }

    /// The number at `i`, written the way it's typed, or kept as words.
    private static func number(_ w: [Word], at i: Int) -> Segment? {
        guard let p = parse(w, from: i) else { return nil }
        var end = i + p.count
        // Another number straight after, without a mark between: two numbers said side by side
        // ("six fifty five", "three five"). Keep the whole stretch as said.
        if !p.ordinal, end < w.count, w[end - 1].trail.isEmpty, w[end].lead.isEmpty, startsNumber(w, at: end),
           !(w[end].key == "and") {
            var e = end
            while e < w.count, startsNumber(w, at: e) || (w[e].key == "and" && e + 1 < w.count && startsNumber(w, at: e + 1)),
                  w[e - 1].trail.isEmpty { e += 1 }
            return Segment(start: i, end: e, text: nil)
        }
        var value = Self.format(p.value)
        // Decimal: "three point six four" → 3.64, "one point five" → 1.5.
        if !p.ordinal, end + 1 < w.count, w[end - 1].trail.isEmpty, w[end].key == "point", w[end].trail.isEmpty,
           let (digits, used) = decimals(w, at: end + 1) {
            value += "." + digits
            end += 1 + used
            return figure(w, i, end, value, forced: true)
        }
        if p.ordinal {
            guard p.value >= 10 else { return Segment(start: i, end: end, text: nil) }
            return Segment(start: i, end: end, text: value + suffix(p.value))
        }
        return figure(w, i, end, value, forced: !p.singleSmall || p.hasScale, small: p.singleSmall ? p.value : nil)
    }

    /// The number with any unit that changes how it's written: %, $, o'clock.
    private static func figure(_ w: [Word], _ start: Int, _ end: Int, _ value: String, forced: Bool, small: Int? = nil) -> Segment {
        let next = end < w.count && w[end - 1].trail.isEmpty ? w[end].key : ""
        switch next {
        case "percent":
            return Segment(start: start, end: end + 1, text: value + "%")
        case "dollars", "dollar":
            var amount = "$" + value
            var e = end + 1
            // "five dollars and fifty cents" → $5.50
            if w[end].trail.isEmpty, e + 2 < w.count, w[e].key == "and", let c = parse(w, from: e + 1),
               c.value < 100, !c.ordinal, e + 1 + c.count < w.count, w[e + 1 + c.count].key == "cents" {
                amount += String(format: ".%02d", c.value)
                e += 2 + c.count
            }
            return Segment(start: start, end: e, text: amount)
        case "o'clock", "oclock":
            if let v = Int(value), (1...12).contains(v) { return Segment(start: start, end: end + 1, text: "\(v):00") }
        default:
            break
        }
        if forced || figureUnits.contains(next) { return Segment(start: start, end: end, text: value) }
        return Segment(start: start, end: end, text: nil, smallValue: small)
    }

    private static func startsNumber(_ w: [Word], at i: Int) -> Bool {
        let k = w[i].key
        return units[k] != nil || teens[k] != nil || tens[k] != nil || scales[k] != nil
    }

    /// Digits after "point": "six four" → "64", "twenty five" → "25".
    private static func decimals(_ w: [Word], at i: Int) -> (String, Int)? {
        var digits = "", j = i
        while j < w.count, let u = units[w[j].key] ?? (w[j].key == "oh" ? 0 : nil) {
            digits += String(u); j += 1
            if !w[j - 1].trail.isEmpty { break }
        }
        if !digits.isEmpty { return (digits, j - i) }
        if let p = parse(w, from: i), !p.ordinal, p.value < 100, !p.hasScale { return (String(p.value), p.count) }
        return nil
    }

    /// Three or more single digits: "three zero two" → 302, "four one five" → 415.
    private static func digitRun(_ w: [Word], at i: Int) -> Segment? {
        var digits = "", j = i
        while j < w.count {
            if j > i, !w[j].lead.isEmpty { break }
            guard let d = units[w[j].key] ?? (w[j].key == "oh" && j > i ? 0 : nil) else { break }
            digits += String(d); j += 1
            if !w[j - 1].trail.isEmpty { break }
        }
        // "oh" can't end it: "one two oh" is more likely "one, two, oh…".
        while digits.count >= 3, w[j - 1].key == "oh" { digits.removeLast(); j -= 1 }
        guard digits.count >= 3 else { return nil }
        // Counting out loud ("one two three") isn't a code.
        if "123456789".hasPrefix(digits) { return nil }
        // A trailing number word would join it into something else ("three five hundred"): leave those.
        if j < w.count, w[j - 1].trail.isEmpty, scales[w[j].key] != nil || tens[w[j].key] != nil { return nil }
        return Segment(start: i, end: j, text: digits)
    }

    /// "twenty nineteen" → 2019, "nineteen ninety" → 1990, "twenty oh five" → 2005,
    /// "twenty twenty five" → 2025.
    private static func year(_ w: [Word], at i: Int) -> Segment? {
        guard i + 1 < w.count, let century = ["nineteen": 19, "twenty": 20][w[i].key], w[i].trail.isEmpty,
              w[i + 1].lead.isEmpty else { return nil }
        var j = i + 1
        var rest: Int?
        let k = w[j].key
        if let t = teens[k] { rest = t; j += 1 }
        else if let t = tens[k] {
            rest = t; j += 1
            if w[j - 1].trail.isEmpty, j < w.count, let u = units[w[j].key], u > 0 { rest = t + u; j += 1 }
        } else if k == "oh", w[j].trail.isEmpty, j + 1 < w.count, let u = units[w[j + 1].key], u > 0 {
            rest = u; j += 2
        }
        guard let r = rest else { return nil }
        // "twenty twenty five hundred" isn't a year.
        if j < w.count, w[j - 1].trail.isEmpty, startsNumber(w, at: j) { return nil }
        // "twenty thirty" could be two quantities but reads as a year far more often in dictation;
        // "twenty five" (tens + unit) is a plain number and never reaches here.
        if century == 20, tens[w[i + 1].key] == nil, teens[w[i + 1].key] == nil, w[i + 1].key != "oh" { return nil }
        return Segment(start: i, end: j, text: String(century * 100 + r))
    }

    private static let hours: [String: Int] = units.filter { $0.value > 0 }.merging(["ten": 10, "eleven": 11, "twelve": 12]) { a, _ in a }

    /// One spoken clock time at `i`: "eleven thirty", "four oh five", "two fifteen". Returns H, MM and words used.
    private static func clock(_ w: [Word], at i: Int) -> (Int, Int, Int)? {
        guard i + 1 < w.count, let h = hours[w[i].key], w[i].trail.isEmpty, w[i + 1].lead.isEmpty else { return nil }
        let k = w[i + 1].key
        if let t = teens[k], t >= 10 { return (h, t, 2) }
        if let t = tens[k], t <= 50 {
            if w[i + 1].trail.isEmpty, i + 2 < w.count, let u = units[w[i + 2].key], u > 0 { return (h, t + u, 3) }
            return (h, t, 2)
        }
        if k == "oh", w[i + 1].trail.isEmpty, i + 2 < w.count, let u = units[w[i + 2].key], u > 0 { return (h, u, 3) }
        return nil
    }

    /// "nine thirty to two thirty" → 9:30 to 2:30: two clock times either side of a range word.
    private static func timeRange(_ w: [Word], at i: Int) -> Segment? {
        guard let (h1, m1, n1) = clock(w, at: i) else { return nil }
        let mid = i + n1
        guard mid + 1 < w.count, w[mid - 1].trail.isEmpty || w[mid - 1].trail == ",",
              rangeWords.contains(w[mid].key), w[mid].trail.isEmpty else { return nil }
        let second: (Int, Int, Int)? = clock(w, at: mid + 1)
        guard let (h2, m2, n2) = second else { return nil }
        let first = "\(h1):" + String(format: "%02d", m1)
        let last = "\(h2):" + String(format: "%02d", m2)
        let joined = first + w[mid - 1].trail + " " + w[mid].lead + w[mid].core + " " + last
        return Segment(start: i, end: mid + 1 + n2, text: joined)
    }

    /// "from ten to four" → 10 to 4: a lone small number keeps step with the other end of its range.
    private static func matchRanges(_ segments: inout [Segment], _ w: [Word]) {
        guard segments.count >= 2 else { return }
        for k in 0..<(segments.count - 1) {
            let a = segments[k], b = segments[k + 1]
            guard a.end + 1 == b.start, rangeWords.contains(w[a.end].key), w[a.end - 1].trail.isEmpty,
                  w[a.end].trail.isEmpty else { continue }
            if a.text != nil, b.text == nil, let v = b.smallValue { segments[k + 1].text = String(v) }
            if b.text != nil, a.text == nil, let v = a.smallValue { segments[k].text = String(v) }
        }
    }

    private static func render(_ tokens: [String], _ w: [Word], _ segments: [Segment]) -> String {
        var out: [String] = []
        var t = 0         // next original token to emit
        for s in segments {
            let firstTok = w[s.start].orig, lastTok = w[s.end - 1].orig
            while t < firstTok { out.append(tokens[t]); t += 1 }
            guard t == firstTok else { continue }
            if let text = s.text {
                // A segment that ends inside a hyphenated token can't be written cleanly: keep it.
                if s.end < w.count, w[s.end].orig == lastTok {
                    while t <= lastTok { out.append(tokens[t]); t += 1 }
                    continue
                }
                out.append(w[s.start].lead + text + w[s.end - 1].trail)
            } else {
                for k in firstTok...lastTok { out.append(tokens[k]) }
            }
            t = lastTok + 1
        }
        while t < tokens.count { out.append(tokens[t]); t += 1 }
        return out.joined(separator: " ")
    }

    // MARK: Formatting

    /// Commas from ten thousand up: 2500 and 2025 read best bare, 12,000 doesn't.
    static func format(_ n: Int) -> String {
        guard n >= 10_000 else { return String(n) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static func suffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}
