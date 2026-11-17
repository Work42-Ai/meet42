import Foundation
import Testing
@testable import Meet42Kit

/// WOR-833: the session type a calendar's events start, with a per-event override.
@Suite("ModesStore session types")
struct ModesStoreTypeTests {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("modes-\(UUID().uuidString).json").path
    }

    @Test("with nothing set, an event starts the event type")
    func defaultsToEvent() {
        let store = ModesStore(path: tempPath())
        #expect(store.effectiveType(forEvent: "e1", calendarId: "c1") == "event")
        #expect(ModesStore.defaultTypeId == "event")
    }

    @Test("the event override beats the calendar default, which beats event")
    func precedence() throws {
        let store = ModesStore(path: tempPath())
        try store.setType(calendar: "work", typeId: "standup")
        #expect(store.effectiveType(forEvent: "e1", calendarId: "work") == "standup")
        #expect(store.effectiveType(forEvent: "e1", calendarId: "personal") == "event")
        try store.setType(event: "e1", typeId: "interview")
        #expect(store.effectiveType(forEvent: "e1", calendarId: "work") == "interview")
        #expect(store.effectiveType(forEvent: "e2", calendarId: "work") == "standup")
    }

    @Test("nil goes back to the default, one level at a time")
    func clearing() throws {
        let store = ModesStore(path: tempPath())
        try store.setType(calendar: "work", typeId: "standup")
        try store.setType(event: "e1", typeId: "interview")
        try store.setType(event: "e1", typeId: nil)
        #expect(store.effectiveType(forEvent: "e1", calendarId: "work") == "standup")
        try store.setType(calendar: "work", typeId: nil)
        #expect(store.effectiveType(forEvent: "e1", calendarId: "work") == "event")
        #expect(store.all().calendarTypes.isEmpty && store.all().eventTypes.isEmpty)
    }

    @Test("types persist across a reload")
    func persists() throws {
        let path = tempPath()
        let first = ModesStore(path: path)
        try first.setType(calendar: "work", typeId: "standup")
        try first.setType(event: "e1", typeId: "interview")
        let second = ModesStore(path: path)
        #expect(second.effectiveType(forEvent: "e1", calendarId: "work") == "interview")
        #expect(second.effectiveType(forEvent: "e2", calendarId: "work") == "standup")
    }

    @Test("a file written before session types existed still loads, with empty type maps")
    func legacyFileDecodes() throws {
        let path = tempPath()
        try Data(#"{"calendars":{"work":"assisted"},"events":{"e1":"view_only"}}"#.utf8).write(to: URL(fileURLWithPath: path))
        let store = ModesStore(path: path)
        #expect(store.calendarMode(for: "work") == .assisted)
        #expect(store.eventMode(for: "e1") == .viewOnly)
        #expect(store.all().calendarTypes.isEmpty)
        #expect(store.all().eventTypes.isEmpty)
        #expect(store.effectiveType(forEvent: "e1", calendarId: "work") == "event")
    }

    @Test("setting a type keeps the assistance modes")
    func keepsModes() throws {
        let store = ModesStore(path: tempPath())
        try store.setCalendarMode(.assisted, for: "work")
        try store.setType(calendar: "work", typeId: "standup")
        #expect(store.calendarMode(for: "work") == .assisted)
    }

    @Test("the JSON a widget reads has both type maps")
    func jsonShape() throws {
        let store = ModesStore(path: tempPath())
        try store.setType(calendar: "work", typeId: "standup")
        try store.setType(event: "e1", typeId: "interview")
        let data = try JSONEncoder().encode(store.all())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["calendarTypes"] as? [String: String]) == ["work": "standup"])
        #expect((object["eventTypes"] as? [String: String]) == ["e1": "interview"])
        #expect(try JSONDecoder().decode(ModesStore.File.self, from: data) == store.all())
    }
}
