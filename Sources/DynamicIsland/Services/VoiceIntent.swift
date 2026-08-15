import Foundation

/// Things that can be created with one phrase and no arguments.
enum QuickLink: String, CaseIterable {
    case googleDoc, googleSheet, googleSlides, googleMeet

    /// Google's own "instant create" endpoints. Hitting one makes the document or
    /// meeting and opens it — no API, no OAuth, no client secret. It works because
    /// the browser is already signed in, which is also the only requirement.
    var url: URL {
        switch self {
        case .googleDoc:    return URL(string: "https://docs.new")!
        case .googleSheet:  return URL(string: "https://sheets.new")!
        case .googleSlides: return URL(string: "https://slides.new")!
        case .googleMeet:   return URL(string: "https://meet.new")!
        }
    }

    var title: String {
        switch self {
        case .googleDoc:    return "New Google Doc"
        case .googleSheet:  return "New Google Sheet"
        case .googleSlides: return "New Google Slides"
        case .googleMeet:   return "New Google Meet"
        }
    }

    /// Ordered most-specific first: "slides" must beat "slide", and "spreadsheet"
    /// must not be swallowed by a looser "sheet" rule elsewhere.
    var keywords: [String] {
        switch self {
        case .googleMeet:   return ["meet", "meeting", "video call", "hangout"]
        case .googleSheet:  return ["spreadsheet", "sheet"]
        case .googleSlides: return ["slides", "slide", "presentation", "deck"]
        case .googleDoc:    return ["document", "doc"]
        }
    }
}

enum VoiceIntent: Equatable {
    case openVault(query: String)
    case createEvent(title: String, start: Date, end: Date)
    case quickLink(QuickLink)
    case unrecognised(reason: String)
}

/// Turns a dictated sentence into an intent.
///
/// Date and time parsing is delegated to `NSDataDetector` rather than hand-rolled
/// regex. It already understands "at 6pm to 7:30pm", "tomorrow at 3", and
/// "at 4pm to 5pm on 8th august 2026", reporting a `duration` for ranges.
///
/// The title is whatever survives once the matched time phrase and the command
/// scaffolding are removed, which is why the filler lists matter more than they
/// look.
struct VoiceIntentParser {

    /// Default event length when a start time is given without an end.
    static let defaultDuration: TimeInterval = 3600

    private static let vaultKeyword = "vault"

    /// Words that introduce a command and carry no meaning in the title.
    ///
    /// `titled`, `called` and `named` matter especially: the natural phrasing
    /// "setup event titled xyz" otherwise produces the title "titled xyz".
    private static let leadingNoise: Set<String> = [
        "setup", "set", "up", "schedule", "add", "create", "make", "put", "book",
        "new", "event", "task", "meeting", "appointment", "reminder",
        "titled", "called", "named", "entitled", "title",
        "please", "hey", "island", "remind", "me", "to", "a", "an", "the", "my",
        "for", "on", "at", "in", "and", "of"
    ]

    private static let vaultNoise: Set<String> = [
        "open", "launch", "start", "load", "switch", "to", "the", "my",
        "vault", "obsidian", "please", "up", "in"
    ]

    /// Verbs that mean "bring something new into existence".
    private static let creationVerbs = [
        "create", "new", "make", "start", "open", "setup", "set up", "give me"
    ]

    /// Tokens proving the speaker named a *date*, not just a time of day.
    private static let explicitDateTokens: [String] = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thurs", "fri", "sat", "sun",
        "today", "tomorrow", "tonight", "yesterday", "next", "this", "/"
    ]

    static func parse(_ transcript: String, now: Date = Date()) -> VoiceIntent {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unrecognised(reason: "Nothing was heard") }

        let lower = text.lowercased()

        // Vault first: an explicit "vault" is unambiguous.
        if lower.contains(vaultKeyword) {
            return parseVault(text)
        }

        // Quick links only when no time was given. "setup doc review at 4pm" is an
        // event that happens to contain the word "doc", not a request for a
        // document — so the presence of a date is what disambiguates.
        let dateMatch = firstDateMatch(in: text)
        if dateMatch == nil, let link = matchQuickLink(lower) {
            return .quickLink(link)
        }

        return parseEvent(text, match: dateMatch, now: now)
    }

    // MARK: - Quick links

    private static func matchQuickLink(_ lower: String) -> QuickLink? {
        guard creationVerbs.contains(where: { lower.contains($0) }) else { return nil }

        // Most-specific kinds first so "slides" isn't captured by "doc".
        for kind in [QuickLink.googleMeet, .googleSlides, .googleSheet, .googleDoc] {
            if kind.keywords.contains(where: { lower.contains($0) }) {
                return kind
            }
        }
        return nil
    }

    // MARK: - Vault

    private static func parseVault(_ text: String) -> VoiceIntent {
        let lower = text.lowercased()
        var candidate = ""

        if let range = lower.range(of: vaultKeyword) {
            let after = String(text[range.upperBound...])
            candidate = strip(after, removing: vaultNoise)
            if candidate.isEmpty {
                candidate = strip(String(text[..<range.lowerBound]), removing: vaultNoise)
            }
        }

        guard !candidate.isEmpty else {
            return .unrecognised(reason: "Which vault? Try “open vault IPM”.")
        }
        return .openVault(query: candidate)
    }

    // MARK: - Event

    private static func firstDateMatch(in text: String) -> NSTextCheckingResult? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: full).first
    }

    private static func parseEvent(_ text: String,
                                   match: NSTextCheckingResult?,
                                   now: Date) -> VoiceIntent {
        guard let match, let start = match.date else {
            return .unrecognised(
                reason: "No time found — try “setup review at 4pm to 5pm”.")
        }

        let phrase = (text as NSString).substring(with: match.range).lowercased()
        let namedADate = explicitDateTokens.contains { phrase.contains($0) }
            || phrase.range(of: #"\b\d{4}\b"#, options: .regularExpression) != nil

        // A bare "4pm" that has already passed today almost certainly means
        // tomorrow. But when the speaker named an actual date — "on 8th August
        // 2026" — moving it is simply wrong, even if that date is in the past.
        var resolvedStart = start
        if !namedADate, resolvedStart < now.addingTimeInterval(-60),
           let bumped = Calendar.current.date(byAdding: .day, value: 1, to: resolvedStart) {
            resolvedStart = bumped
        }

        let duration = match.duration > 0 ? match.duration : defaultDuration
        let end = resolvedStart.addingTimeInterval(duration)

        let withoutTime = (text as NSString).replacingCharacters(in: match.range, with: " ")
        let title = strip(withoutTime, removing: leadingNoise)

        guard !title.isEmpty else {
            return .unrecognised(reason: "What should the event be called?")
        }
        return .createEvent(title: title, start: resolvedStart, end: end)
    }

    // MARK: - Cleanup

    /// Drops noise words from both ends, keeping interior words intact so
    /// "one to one with Sam" doesn't lose its middle.
    private static func strip(_ text: String, removing noise: Set<String>) -> String {
        var words = text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }

        while let first = words.first, noise.contains(first.lowercased()) {
            words.removeFirst()
        }
        while let last = words.last, noise.contains(last.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}
