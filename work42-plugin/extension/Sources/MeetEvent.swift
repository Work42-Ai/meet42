// MeetEvent.swift — shared by the Event details, Recording and Calendar widgets (copied into each widget's
// Sources by scripts/sync-shared.sh, because every widget compiles on its own).
//
// The session stores only the calendar event id (`meeting/event_id`); everything else is read live through
// `meet42 show <id> --json`. This file holds the tolerant decoder for that output, the loader, the avatar style
// (so a person looks the same in the guest list, the transcript and the header label), the RSVP grouping, the meeting
// provider detection and the relative-time label.

import Foundation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - The event

struct MeetEvent: Decodable {

    struct Attendee: Decodable {
        let name: String?
        let email: String?
        let status: String
        let isOrganizer: Bool
        let isCurrentUser: Bool

        private enum Keys: String, CodingKey { case name, email, status, isOrganizer, isCurrentUser }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            email = try c.decodeIfPresent(String.self, forKey: .email)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
            isOrganizer = try c.decodeIfPresent(Bool.self, forKey: .isOrganizer) ?? false
            isCurrentUser = try c.decodeIfPresent(Bool.self, forKey: .isCurrentUser) ?? false
        }

        /// Name when the calendar has one, else the email.
        var displayName: String {
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
            return email ?? "(unknown)"
        }
    }

    let id: String
    let title: String
    let calendarTitle: String?
    let source: String
    let status: String
    let location: String?
    let organizer: String?
    let notesHTML: String?
    let meetingURL: String?
    let calendarColor: String?
    /// The Work42 session minted for this event (AI-assisted calendars), when there is one.
    let sessionId: String?
    let startsAt: Date
    let endsAt: Date
    let allDay: Bool
    let attendees: [Attendee]

    private enum Keys: String, CodingKey {
        case id, title, calendarTitle, source, status, location, organizer, notesHTML, meetingURL
        case calendarColor, sessionId, startsAt, endsAt, allDay, attendees
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        calendarTitle = try c.decodeIfPresent(String.self, forKey: .calendarTitle)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "other"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "none"
        location = try c.decodeIfPresent(String.self, forKey: .location)
        organizer = try c.decodeIfPresent(String.self, forKey: .organizer)
        notesHTML = try c.decodeIfPresent(String.self, forKey: .notesHTML)
        meetingURL = try c.decodeIfPresent(String.self, forKey: .meetingURL)
        calendarColor = try c.decodeIfPresent(String.self, forKey: .calendarColor)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        startsAt = try c.decode(Date.self, forKey: .startsAt)
        endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt) ?? startsAt
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        attendees = try c.decodeIfPresent([Attendee].self, forKey: .attendees) ?? []
    }
}

// MARK: - Loading

enum MeetEventState {
    /// The session has no calendar event (an ad-hoc event session).
    case unlinked
    case loaded(MeetEvent)
    /// The event could not be read from the calendars; `command` names what was asked and `message` says why, both shown to the user.
    case failed(command: String, message: String)
}

extension MeetEvent.Attendee {
    init(name: String?, email: String?, status: String, isOrganizer: Bool, isCurrentUser: Bool) {
        self.name = name
        self.email = email
        self.status = status
        self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser
    }
}

extension MeetEvent {

    /// The event as Work42's calendar service describes it (`services.calendar`), in the shape the widgets draw. The session Work42
    /// minted for an event is not part of the calendar, so `sessionId` is nil here.
    init(calendar event: CalendarEvent) {
        id = event.id
        title = event.title
        calendarTitle = event.calendar
        source = event.source ?? "other"
        status = event.status ?? "none"
        location = event.location
        organizer = event.organizer
        notesHTML = event.notes
        meetingURL = event.url
        calendarColor = event.calendarColor
        sessionId = nil
        startsAt = event.start
        endsAt = event.end
        allDay = event.isAllDay
        if let details = event.attendeeDetails {
            attendees = details.map {
                Attendee(name: $0.name, email: $0.email, status: $0.status, isOrganizer: $0.isOrganizer, isCurrentUser: $0.isCurrentUser)
            }
        } else {
            attendees = event.attendees.map { Attendee(name: $0, email: nil, status: "unknown", isOrganizer: false, isCurrentUser: false) }
        }
    }
}

enum MeetEventLoader {

    /// How far each side of today an event is looked for when only its id is known. EventKit answers by date range, never by id.
    static let lookBehind: TimeInterval = 365 * 86_400
    static let lookAhead: TimeInterval = 365 * 86_400

    /// The session's linked event: its id comes from session storage `meeting/event_id`.
    static func load(calendar: any WidgetCalendarService, storage: any WidgetStorageService, now: Date = Date()) async -> MeetEventState {
        guard case .string(let id)? = try? await storage.get(namespace: "meeting", key: "event_id"), !id.isEmpty else {
            return .unlinked
        }
        return await load(eventID: id, calendar: calendar, now: now)
    }

    /// One event by its calendar id. The id is EventKit's `eventIdentifier`, which is what `services.calendar` reports as `id`.
    static func load(eventID id: String, calendar: any WidgetCalendarService, now: Date = Date()) async -> MeetEventState {
        let command = "calendar event \(id)"
        do {
            if let found = try await find(eventID: id, calendar: calendar, now: now) { return .loaded(MeetEvent(calendar: found)) }
            return .failed(command: command, message: "That event is no longer in your calendars.")
        } catch {
            let detail = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(command: command, message: detail.isEmpty ? "Couldn\u{2019}t read your calendar." : detail)
        }
    }

    /// The event with this id, or nil when it is in no calendar. Shared by the tiles and the `get_event` tool.
    static func find(eventID id: String, calendar: any WidgetCalendarService, now: Date = Date()) async throws -> CalendarEvent? {
        // Around now first (an event you are about to open is almost always near), then the whole window.
        let near = try await calendar.events(from: now.addingTimeInterval(-14 * 86_400), to: now.addingTimeInterval(60 * 86_400))
        if let found = near.first(where: { $0.id == id }) { return found }
        let wide = try await calendar.events(from: now.addingTimeInterval(-lookBehind), to: now.addingTimeInterval(lookAhead))
        return wide.first(where: { $0.id == id })
    }

    /// POSIX single-quote escaping for a value interpolated into a `/bin/sh -c` command line.
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private func shellQuote(_ value: String) -> String { MeetEventLoader.shellQuote(value) }

// MARK: - Meeting provider

struct MeetProvider {
    let name: String
    let brandHex: String?

    static func detect(_ urlString: String?) -> MeetProvider? {
        guard let urlString, let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        if host == "meet.google.com" { return MeetProvider(name: "Google Meet", brandHex: "#00832D") }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return MeetProvider(name: "Zoom", brandHex: "#0B5CFF") }
        if host == "teams.microsoft.com" || host == "teams.live.com" { return MeetProvider(name: "Microsoft Teams", brandHex: "#5B5FC7") }
        if host == "webex.com" || host.hasSuffix(".webex.com") { return MeetProvider(name: "Webex", brandHex: "#07C160") }
        return MeetProvider(name: host, brandHex: nil)
    }

    /// The name of a calendar source for the chip next to the calendar title.
    static func sourceName(_ source: String) -> String {
        switch source {
        case "exchange": return "Outlook"
        case "icloud": return "iCloud"
        case "google": return "Google"
        case "caldav": return "CalDAV"
        case "local": return "On My Mac"
        default: return "Calendar"
        }
    }
}

// MARK: - RSVP

enum MeetRSVP: Int, CaseIterable {
    case going, maybe, noReply, declined

    init(status: String) {
        switch status {
        case "accepted": self = .going
        case "tentative": self = .maybe
        case "declined": self = .declined
        default: self = .noReply          // pending and unknown
        }
    }

    var title: String {
        switch self {
        case .going: return "Going"
        case .maybe: return "Maybe"
        case .noReply: return "No reply"
        case .declined: return "Declined"
        }
    }

    var symbol: String {
        switch self {
        case .going: return "checkmark.circle.fill"
        case .maybe: return "questionmark.circle.fill"
        case .noReply: return "minus.circle.fill"
        case .declined: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .going: return DT.green
        case .maybe: return DT.amber
        case .noReply: return DT.textTertiary
        case .declined: return DT.red
        }
    }
}

extension MeetEvent {
    func count(_ group: MeetRSVP) -> Int { attendees.filter { MeetRSVP(status: $0.status) == group }.count }
    /// True when anyone is tentative, pending or unknown (the guests label turns amber).
    var hasOpenReplies: Bool { count(.maybe) + count(.noReply) > 0 }
}

// MARK: - Avatars

/// One avatar style everywhere (guest list, transcript, header label). A person's colour comes from their email
/// (else their name), so they look the same in every widget.
enum MeetAvatar {

    /// One plain colour per slot: the glass is tinted with it and the initials are drawn in it.
    /// (Each is the deeper stop of the gradient pair the avatars used before WOR-235.)
    static let palette: [Color] = [
        Color(red: 1.00, green: 0.24, blue: 0.43),
        Color(red: 0.15, green: 0.39, blue: 0.92),
        Color(red: 0.05, green: 0.65, blue: 0.42),
        Color(red: 0.43, green: 0.16, blue: 0.85),
        Color(red: 0.91, green: 0.47, blue: 0.06),
        Color(red: 0.36, green: 0.40, blue: 0.44),
    ]

    /// FNV-1a over the lowercased key, mod the palette size: stable across launches (unlike `hashValue`).
    static func paletteIndex(for key: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(palette.count))
    }

    static func key(name: String?, email: String?) -> String {
        if let email, !email.isEmpty { return email }
        return name ?? "?"
    }

    /// First letters of the first and last name words; else the first two letters of the email's local part.
    static func initials(name: String?, email: String?) -> String {
        let words = (name ?? "").split(whereSeparator: { $0 == " " || $0 == "." }).filter { !$0.isEmpty }
        if words.count >= 2, let a = words.first?.first, let b = words.last?.first { return "\(a)\(b)".uppercased() }
        if let first = words.first { return String(first.prefix(2)).uppercased() }
        if let local = email?.split(separator: "@").first { return String(local.prefix(2)).uppercased() }
        return "?"
    }
}

/// The one avatar look: a liquid-glass circle tinted with a single plain colour, initials in that
/// colour (`GlassAvatar` in Work42UI, shared with the chat). `color` overrides the person's palette
/// colour (used for You, Speaker N and Them). `stacked` backs the glass with a solid disc so
/// overlapping avatars stay distinguishable.
struct MeetAvatarView: View {
    let initials: String
    let key: String
    var size: CGFloat = 30
    var color: Color?
    var stacked = false

    var body: some View {
        let tint = color ?? MeetAvatar.palette[MeetAvatar.paletteIndex(for: key)]
        GlassAvatar(initials: initials, color: tint, size: size)
            .background {
                if stacked {
                    #if os(macOS)
                    Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2)
                    #else
                    Circle().fill(Color(uiColor: .systemBackground)).padding(-2)
                    #endif
                }
            }
    }
}

// MARK: - Relative time

enum MeetTimeLabel {

    /// The header label text and tint for an event at `now`, or nil when there is nothing to say yet.
    /// "Starts in N min" (from 60 minutes before), "Live · N min left", "Ended h:mm".
    static func label(for event: MeetEvent, now: Date = Date()) -> (text: String, tint: WidgetHeaderLabelTint)? {
        if event.allDay { return nil }
        let untilStart = event.startsAt.timeIntervalSince(now)
        let untilEnd = event.endsAt.timeIntervalSince(now)
        if untilEnd <= 0 {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return ("Ended \(f.string(from: event.endsAt))", .neutral)
        }
        if untilStart <= 0 {
            return ("Live \u{00B7} \(minutes(untilEnd)) left", .success)
        }
        if untilStart <= 3600 {
            return ("Starts in \(minutes(untilStart))", .accent)
        }
        return nil
    }

    private static func minutes(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return "\(m) min"
    }
}
