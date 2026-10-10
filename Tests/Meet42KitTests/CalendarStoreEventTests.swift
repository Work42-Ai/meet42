import Foundation
import Testing
@testable import Meet42Kit

@MainActor
@Suite struct CalendarStoreEventTests {

    private func makeStore() throws -> (CalendarStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m42-\(UUID().uuidString).db")
        return (try CalendarStore(databasePath: url.path), url)
    }

    private func item(_ id: String, color: String?, start: Date) -> CalendarEvent.Item {
        CalendarEvent.Item(
            id: id, calendarId: "cal", calendarTitle: "Work", source: .google, title: "Event \(id)",
            notes: nil, location: nil, startsAt: start, endsAt: start.addingTimeInterval(1800), allDay: false,
            organizer: nil, attendees: [], status: .confirmed, url: nil, meetingURL: nil, lastModified: nil,
            syncedAt: Date(), sessionId: nil, sessionDir: nil, prepFiredAt: nil, calendarColor: color
        )
    }

    @Test func calendarColorRoundTrips() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date().addingTimeInterval(3600)
        try store.upsert(item("a", color: "#2563EB", start: start))
        #expect(try store.event(id: "a")?.calendarColor == "#2563EB")
        // A later sync that has no colour must not wipe the stored one.
        try store.upsert(item("a", color: nil, start: start))
        #expect(try store.event(id: "a")?.calendarColor == "#2563EB")
    }

    @Test func replaceWindowKeepsEventsLinkedToASession() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date().addingTimeInterval(3600)
        let from = start.addingTimeInterval(-3600), to = start.addingTimeInterval(7200)
        try store.upsert(item("linked", color: nil, start: start))
        try store.upsert(item("unlinked", color: nil, start: start))
        try store.linkSession(eventId: "linked", sessionId: "s1", sessionDir: "/tmp/s1")

        // The calendar no longer has either event.
        try store.replaceWindow(from: from, to: to, items: [])

        #expect(try store.event(id: "linked") != nil)
        #expect(try store.event(id: "unlinked") == nil)
    }
}
