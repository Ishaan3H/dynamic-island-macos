import EventKit
import Foundation

/// Creates calendar events through EventKit.
///
/// **Why not the Google Calendar API directly?** If the Google account is added in
/// System Settings → Internet Accounts, macOS syncs it over CalDAV and EventKit
/// writes straight into it — the event appears in Google Calendar within seconds.
/// Going direct would mean an OAuth client, a consent screen, a client secret on
/// disk, and refresh-token handling, all to reach a calendar the system already
/// has a live connection to.
///
/// The trade-off is a real prerequisite: **the account must be connected in
/// System Settings.** `preferredCalendar()` reports what it actually found so the
/// UI can say where an event landed rather than claiming success vaguely.
final class CalendarService {

    private let store = EKEventStore()

    enum AccessState: Equatable {
        case unknown
        case granted
        case denied
    }

    private(set) var access: AccessState = .unknown

    // MARK: - Authorisation

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                self?.access = granted ? .granted : .denied
                completion(granted)
            }
        }

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    // MARK: - Calendar selection

    static func isSynced(_ calendar: EKCalendar) -> Bool {
        calendar.source?.sourceType == .calDAV || calendar.source?.sourceType == .exchange
    }

    /// Picks where dictated events go, in descending order of "the user actually
    /// meant this".
    ///
    /// An earlier version simply took the first writable synced calendar. On a real
    /// account that is effectively random — it chose a subject calendar called
    /// "Physical" over the primary one, and would have filed everything there
    /// silently. Ordering matters more than it looks:
    ///
    /// 1. An explicit choice in `config.json` always wins.
    /// 2. Otherwise the user's *own* default for new events, if it syncs — they
    ///    already expressed a preference in Calendar.app.
    /// 3. Otherwise the account's primary calendar. Google names it after the
    ///    address, so a title containing "@" identifies it.
    /// 4. Otherwise any synced calendar, then finally a local one.
    func preferredCalendar() -> EKCalendar? {
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        guard !writable.isEmpty else { return nil }

        if let wanted = Config.shared.calendarTitle,
           let chosen = writable.first(where: {
               $0.title.caseInsensitiveCompare(wanted) == .orderedSame
           }) {
            return chosen
        }

        if let systemDefault = store.defaultCalendarForNewEvents,
           systemDefault.allowsContentModifications,
           Self.isSynced(systemDefault) {
            return systemDefault
        }

        if let primary = writable.first(where: { Self.isSynced($0) && $0.title.contains("@") }) {
            return primary
        }

        if let synced = writable.first(where: { Self.isSynced($0) }) {
            return synced
        }
        return store.defaultCalendarForNewEvents ?? writable.first
    }

    /// Titles of every writable calendar, for the config file and the UI.
    func writableCalendarTitles() -> [String] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map(\.title)
            .sorted()
    }

    /// Human-readable description of where events will go, for the UI.
    func destinationDescription() -> String? {
        guard let calendar = preferredCalendar() else { return nil }
        let account = calendar.source?.title
        let isSynced = calendar.source?.sourceType == .calDAV
            || calendar.source?.sourceType == .exchange

        if let account, isSynced { return "\(calendar.title) · \(account)" }
        if let account { return "\(calendar.title) · \(account) (local only)" }
        return calendar.title
    }

    /// True when no synced account exists, so the UI can warn that an event will
    /// not reach Google rather than reporting a hollow success.
    var isLocalOnly: Bool {
        guard let source = preferredCalendar()?.source else { return true }
        return source.sourceType != .calDAV && source.sourceType != .exchange
    }

    // MARK: - Diagnostics

    /// Human-readable report of every writable calendar and which account it
    /// belongs to, plus where a dictated event would actually land.
    ///
    /// Worth having permanently: "my event saved but never showed up on my phone"
    /// is otherwise very hard to diagnose, because a local-only calendar succeeds
    /// just as loudly as a synced one.
    func report() -> [String] {
        let all = store.calendars(for: .event)
        guard !all.isEmpty else {
            return ["No calendars visible. Is a calendar account enabled in System Settings?"]
        }

        var lines: [String] = []
        let grouped = Dictionary(grouping: all) { $0.source?.title ?? "(no account)" }

        for (account, calendars) in grouped.sorted(by: { $0.key < $1.key }) {
            let type = calendars.first?.source?.sourceType
            lines.append("\(account)  [\(Self.describe(type))]")
            for calendar in calendars.sorted(by: { $0.title < $1.title }) {
                let writable = calendar.allowsContentModifications ? "writable" : "read-only"
                lines.append("    • \(calendar.title) — \(writable)")
            }
        }

        lines.append("")
        if let systemDefault = store.defaultCalendarForNewEvents {
            lines.append("Calendar.app default: \(systemDefault.title) · \(systemDefault.source?.title ?? "?")")
        }
        if let override = Config.shared.calendarTitle {
            lines.append("config.json override: \(override)")
        }
        lines.append("")
        if let chosen = preferredCalendar() {
            lines.append("Dictated events → \(chosen.title) · \(chosen.source?.title ?? "?")")
            let account = chosen.source?.title ?? "that account"
            lines.append(isLocalOnly
                ? "WARNING: local only — events will NOT sync anywhere."
                : "This calendar syncs, so events will appear in \(account).")
            lines.append("")
            lines.append("To send them elsewhere, set \"calendarTitle\" in config.json to one of:")
            lines.append("  " + writableCalendarTitles().joined(separator: ", "))
        } else {
            lines.append("No writable calendar found — events cannot be created.")
        }
        return lines
    }

    private static func describe(_ type: EKSourceType?) -> String {
        switch type {
        case .local:       return "on this Mac only"
        case .calDAV:      return "synced (CalDAV)"
        case .exchange:    return "synced — Exchange"
        case .subscribed:  return "subscribed, read-only"
        case .birthdays:   return "birthdays"
        case .mobileMe:    return "synced (iCloud)"
        default:           return "unknown"
        }
    }

    // MARK: - Writing

    enum CalendarError: LocalizedError {
        case noCalendar
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCalendar:
                return "No writable calendar. Add an account in System Settings → Internet Accounts."
            case .saveFailed(let message):
                return message
            }
        }
    }

    func createEvent(
        title: String,
        start: Date,
        end: Date,
        completion: @escaping (Result<EKEvent, Error>) -> Void
    ) {
        guard let calendar = preferredCalendar() else {
            completion(.failure(CalendarError.noCalendar))
            return
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(60))
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent, commit: true)
            Log.debug("calendar: created \"\(title)\" in \(calendar.title)")
            completion(.success(event))
        } catch {
            completion(.failure(CalendarError.saveFailed(error.localizedDescription)))
        }
    }
}
