// CalendarIngest.swift — the person's calendar events, as Work42 read them, into meet42's own copy (WOR-890).
//
// meet42 used to read EventKit itself and so held the Calendar permission. Work42 now holds it: the meet42 extension reads the
// calendars through `services.calendar`, writes the events to a JSON file and runs `meet42 sync --events <file>`, which maps
// them to `CalendarEvent.Item`s here. The mapping is the one the EventKit sync made, so an event keeps the id its session and
// its assistance mode are filed under: the event's identifier, then `:`, then its start as a fractional-seconds ISO 8601 string
// (an identifier is the same for every occurrence of a recurring event).

import Foundation

public nonisolated enum CalendarIngest {

    /// One event as Work42PluginKit's `CalendarEvent` encodes it. Everything past the dates and title is optional: a host that
    /// cannot tell leaves it out.
    struct Incoming: Decodable {
        struct Attendee: Decodable {
            var name: String?
            var email: String?
            var status: String?
            var isOrganizer: Bool?
            var isCurrentUser: Bool?
        }

        var id: String
        var title: String?
        var start: Date
        var end: Date
        var isAllDay: Bool?
        var location: String?
        var notes: String?
        var attendees: [String]?
        var calendar: String?
        var calendarId: String?
        var calendarColor: String?
        var source: String?
        var organizer: String?
        var attendeeDetails: [Attendee]?
        var status: String?
        var url: String?
        var lastModified: Date?
    }

    public struct IngestError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Decodes `data` (a JSON array of events) and maps each to the row meet42 keeps. An event with no identifier is dropped,
    /// as the EventKit sync dropped it.
    public static func items(from data: Data, syncedAt: Date) throws -> [CalendarEvent.Item] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
            }
            return date
        }
        let incoming: [Incoming]
        do {
            incoming = try decoder.decode([Incoming].self, from: data)
        } catch {
            throw IngestError(message: "the events file is not a JSON array of calendar events: \(error)")
        }
        return incoming.compactMap { map($0, syncedAt: syncedAt) }
    }

    static func map(_ event: Incoming, syncedAt: Date) -> CalendarEvent.Item? {
        guard !event.id.isEmpty else { return nil }
        let attendees: [CalendarEvent.Attendee]
        if let details = event.attendeeDetails {
            attendees = details.map {
                CalendarEvent.Attendee(
                    name: $0.name, email: $0.email, status: CalendarEvent.AttendeeStatus(rawValue: $0.status ?? "") ?? .unknown,
                    isOrganizer: $0.isOrganizer ?? false, isCurrentUser: $0.isCurrentUser ?? false)
            }
        } else {
            // A host that sent only names: keep the people, with no answer.
            attendees = (event.attendees ?? []).map {
                CalendarEvent.Attendee(name: $0, email: $0.contains("@") ? $0 : nil, status: .unknown, isOrganizer: false, isCurrentUser: false)
            }
        }
        let title = (event.title ?? "").isEmpty ? "(Untitled)" : event.title ?? "(Untitled)"
        return CalendarEvent.Item(
            id: "\(event.id):\(iso(event.start))",
            calendarId: event.calendarId ?? "",
            calendarTitle: event.calendar,
            source: CalendarEvent.Source(rawValue: event.source ?? "") ?? .other,
            title: title,
            notes: event.notes,
            location: event.location,
            startsAt: event.start,
            endsAt: event.end,
            allDay: event.isAllDay ?? false,
            organizer: event.organizer,
            attendees: attendees,
            status: CalendarEvent.Status(rawValue: event.status ?? "") ?? .none,
            url: event.url,
            meetingURL: CalendarEvent.extractMeetingURL(url: event.url, location: event.location, notes: event.notes),
            lastModified: event.lastModified,
            syncedAt: syncedAt,
            sessionId: nil,
            sessionDir: nil,
            prepFiredAt: nil,
            calendarColor: event.calendarColor)
    }

    /// An ISO 8601 date with or without fractional seconds.
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: text)
    }

    /// The form an occurrence id carries the start in: `2026-11-25T10:00:00.000Z`.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
