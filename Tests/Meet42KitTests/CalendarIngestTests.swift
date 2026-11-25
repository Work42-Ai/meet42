import Foundation
import Testing
@testable import Meet42Kit

/// WOR-890: the events Work42 read from the calendars become meet42's own rows, with the ids the EventKit sync gave them.
@Suite("CalendarIngest")
struct CalendarIngestTests {

    private let syncedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func items(_ json: String) throws -> [CalendarEvent.Item] {
        try CalendarIngest.items(from: Data(json.utf8), syncedAt: syncedAt)
    }

    @Test("an occurrence id is the event identifier, a colon and the start with fractional seconds")
    func occurrenceId() throws {
        let rows = try items(#"[{"id":"EK-1","title":"Standup","start":"2026-11-25T10:00:00Z","end":"2026-11-25T10:30:00Z"}]"#)
        #expect(rows.map(\.id) == ["EK-1:2026-11-25T10:00:00.000Z"])
    }

    @Test("a full event keeps its calendar, colour, source, organizer, answers, status and links")
    func fullEvent() throws {
        let rows = try items("""
        [{"id":"E","title":"Roadmap","start":"2026-11-25T10:00:00.000Z","end":"2026-11-25T11:00:00.000Z","isAllDay":false,
          "location":"Room 4","notes":"Join https://meet.google.com/abc-defg-hij","attendees":["Ada"],"calendar":"Work",
          "calendarId":"cal-1","calendarColor":"#1BADF8","source":"google","organizer":"Ada","status":"tentative",
          "url":"https://example.com/e","lastModified":"2026-11-20T09:00:00Z",
          "attendeeDetails":[{"name":"Ada","email":"ada@example.com","status":"accepted","isOrganizer":true,"isCurrentUser":false},
                             {"name":"Me","status":"pending","isCurrentUser":true}]}]
        """)
        let event = try #require(rows.first)
        #expect(event.calendarId == "cal-1" && event.calendarTitle == "Work" && event.calendarColor == "#1BADF8")
        #expect(event.source == .google && event.status == .tentative && event.organizer == "Ada")
        #expect(event.meetingURL == "https://meet.google.com/abc-defg-hij")
        #expect(event.attendees.map(\.status) == [.accepted, .pending])
        #expect(event.attendees[0].isOrganizer && event.attendees[1].isCurrentUser)
        #expect(event.attendees[0].email == "ada@example.com" && event.attendees[1].email == nil)
        #expect(event.lastModified != nil && event.syncedAt == syncedAt && event.sessionId == nil)
    }

    @Test("a host that left the optional fields out still gives a row: other source, no status, untitled")
    func sparseEvent() throws {
        let rows = try items(#"[{"id":"E","title":"","start":"2026-11-25T10:00:00Z","end":"2026-11-25T11:00:00Z","attendees":["ada@example.com","Bo"]}]"#)
        let event = try #require(rows.first)
        #expect(event.title == "(Untitled)" && event.source == .other && event.status == CalendarEvent.Status.none)
        #expect(event.calendarId == "" && event.allDay == false)
        #expect(event.attendees.map(\.email) == ["ada@example.com", nil])
    }

    @Test("an unknown source, status or answer falls back rather than failing the sync")
    func unknownValues() throws {
        let rows = try items("""
        [{"id":"E","title":"x","start":"2026-11-25T10:00:00Z","end":"2026-11-25T11:00:00Z","source":"icq","status":"maybe",
          "attendeeDetails":[{"name":"A","status":"delegated"}]}]
        """)
        let event = try #require(rows.first)
        #expect(event.source == .other && event.status == CalendarEvent.Status.none && event.attendees[0].status == .unknown)
    }

    @Test("an event with no identifier is dropped, as the EventKit sync dropped it")
    func noIdentifier() throws {
        #expect(try items(#"[{"id":"","title":"x","start":"2026-11-25T10:00:00Z","end":"2026-11-25T11:00:00Z"}]"#).isEmpty)
    }

    @Test("dates are read with or without fractional seconds, and something else is refused with a message")
    func dates() throws {
        let rows = try items("""
        [{"id":"A","title":"a","start":"2026-11-25T10:00:00.500Z","end":"2026-11-25T11:00:00Z"}]
        """)
        #expect(rows[0].startsAt.timeIntervalSince(rows[0].endsAt) == -3599.5)
        #expect(throws: CalendarIngest.IngestError.self) { try items("not json") }
        #expect(throws: CalendarIngest.IngestError.self) {
            try items(#"[{"id":"A","title":"a","start":"yesterday","end":"2026-11-25T11:00:00Z"}]"#)
        }
    }

    @Test("a window sync writes the rows to the store and a later one replaces them")
    @MainActor
    func writesToStore() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try CalendarStore(databasePath: path)
        let from = Date(timeIntervalSince1970: 1_790_000_000), to = from.addingTimeInterval(90 * 86_400)
        try store.replaceWindow(from: from, to: to, items: try items(
            #"[{"id":"A","title":"a","start":"2026-11-25T10:00:00Z","end":"2026-11-25T11:00:00Z","calendarId":"c"}]"#))
        #expect(try store.events(from: from, to: to).map(\.title) == ["a"])
        try store.replaceWindow(from: from, to: to, items: try items(
            #"[{"id":"B","title":"b","start":"2026-11-25T12:00:00Z","end":"2026-11-25T13:00:00Z","calendarId":"c"}]"#))
        #expect(try store.events(from: from, to: to).map(\.title) == ["b"])
    }
}
