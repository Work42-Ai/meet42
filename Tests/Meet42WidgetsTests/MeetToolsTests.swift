// MeetToolsTests.swift — the meet42 MCP tools and the event loader that no longer shells out to the CLI (WOR-901).

import Foundation
import Testing
import Work42PluginKit
@testable import Meet42PluginWidgets

private nonisolated final class FakeCalendar: WidgetCalendarService, @unchecked Sendable {
    private let lock = NSLock()
    private let all: [CalendarEvent]
    private var asked: [(Date, Date)] = []
    var failure: (any Error)?

    init(_ events: [CalendarEvent]) { all = events }

    var windows: [(Date, Date)] { lock.withLock { asked } }

    nonisolated func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        lock.withLock { asked.append((from, to)) }
        if let failure { throw failure }
        return all.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
    }
}

private nonisolated final class MemoryStorage: WidgetStorageService, @unchecked Sendable {
    let values: [String: WidgetJSONValue]
    init(_ values: [String: WidgetJSONValue]) { self.values = values }
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { values["\(namespace)/\(key)"] }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func event(_ id: String, daysFromNow: Double, title: String = "Standup") -> CalendarEvent {
    let start = now.addingTimeInterval(daysFromNow * 86_400)
    return CalendarEvent(id: id, title: title, start: start, end: start.addingTimeInterval(1800), calendar: "Work")
}

@Suite("meet42 tools")
struct MeetToolsTests {

    // MARK: transcript

    @Test("the transcript keeps the latest lines, oldest first, and counts them all")
    func transcriptLatest() {
        var text = ""
        for index in 1...5 {
            text += #"{"ts":"2026-01-01T10:00:0\#(index)Z","speaker":"\#(index % 2 == 0 ? "Them" : "You")","text":"line \#(index)","audioStartSeconds":\#(index).5,"audioEndSeconds":\#(index + 1)}"# + "\n"
        }
        let read = MeetTranscript.lines(in: Data(text.utf8), limit: 2)
        #expect(read.total == 5)
        #expect(read.lines.map(\.text) == ["line 4", "line 5"])
        #expect(read.lines.first?.speaker == "Them")
        #expect(read.lines.first?.audioStartSeconds == 4.5)
    }

    @Test("a half-written, empty or non-JSON line is skipped")
    func transcriptSkipsBadLines() {
        let text = #"{"speaker":"You","text":"ok"}"# + "\nnot json\n" + #"{"speaker":"You","text":"  "}"# + "\n" + #"{"speaker":"Them","te"#
        let read = MeetTranscript.lines(in: Data(text.utf8), limit: nil)
        #expect(read.total == 1)
        #expect(read.lines.map(\.text) == ["ok"])
    }

    @Test("the limit is at least 1 and at most 500; the default is 100")
    func transcriptLimits() {
        let text = (1...600).map { #"{"speaker":"You","text":"l\#($0)"}"# }.joined(separator: "\n")
        #expect(MeetTranscript.lines(in: Data(text.utf8), limit: nil).lines.count == 100)
        #expect(MeetTranscript.lines(in: Data(text.utf8), limit: 9999).lines.count == 500)
        #expect(MeetTranscript.lines(in: Data(text.utf8), limit: 0).lines.count == 1)
        #expect(MeetTranscript.lines(in: Data(), limit: nil).lines.isEmpty)
    }

    // MARK: events

    @Test("an event answers with ISO dates and its attendees")
    func summary() throws {
        var calendarEvent = event("a", daysFromNow: 1)
        calendarEvent.attendees = ["Ana", "Bo"]
        let summary = MeetEventSummary(calendarEvent)
        #expect(summary.id == "a")
        #expect(summary.start == ISO8601DateFormatter().string(from: calendarEvent.start))
        #expect(summary.attendees.map(\.name) == ["Ana", "Bo"])
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(json.contains("\"all_day\""))
    }

    @Test("the list window defaults to a week, rejects a reversed or over-long window, and sorts soonest first")
    func listing() throws {
        let window = try MeetEventListing.window(from: nil, to: nil, now: now)
        #expect(window.from == now && window.to == now.addingTimeInterval(7 * 86_400))
        #expect(throws: PluginToolFailure.self) { try MeetEventListing.window(from: now, to: now.addingTimeInterval(-1), now: now) }
        #expect(throws: PluginToolFailure.self) { try MeetEventListing.window(from: now, to: now.addingTimeInterval(91 * 86_400), now: now) }
        let sorted = MeetEventListing.summaries([event("late", daysFromNow: 3), event("soon", daysFromNow: 1)])
        #expect(sorted.map(\.id) == ["soon", "late"])
    }

    @Test("the loader finds a near event with one calendar read and a far one with two")
    func loaderFinds() async throws {
        let calendar = FakeCalendar([event("near", daysFromNow: 2), event("far", daysFromNow: 200)])
        let near = try await MeetEventLoader.find(eventID: "near", calendar: calendar, now: now)
        #expect(near?.id == "near")
        #expect(calendar.windows.count == 1)
        let far = try await MeetEventLoader.find(eventID: "far", calendar: calendar, now: now)
        #expect(far?.id == "far")
        #expect(calendar.windows.count == 3)
        #expect(try await MeetEventLoader.find(eventID: "gone", calendar: calendar, now: now) == nil)
    }

    @Test("the session's event is loaded from meeting/event_id, and says so when it is gone or the calendar fails")
    func loadStates() async {
        let calendar = FakeCalendar([event("e1", daysFromNow: 1, title: "Planning")])
        let storage = MemoryStorage(["meeting/event_id": .string("e1")])
        if case .loaded(let loaded) = await MeetEventLoader.load(calendar: calendar, storage: storage, now: now) {
            #expect(loaded.title == "Planning")
        } else {
            Issue.record("the event was not loaded")
        }
        if case .unlinked = await MeetEventLoader.load(calendar: calendar, storage: MemoryStorage([:]), now: now) {} else {
            Issue.record("a session with no event_id is unlinked")
        }
        if case .failed(_, let message) = await MeetEventLoader.load(eventID: "nope", calendar: calendar, now: now) {
            #expect(message.contains("no longer"))
        } else {
            Issue.record("a missing event fails")
        }
        calendar.failure = WidgetServiceError.hostLacks("calendar")
        if case .failed = await MeetEventLoader.load(eventID: "e1", calendar: calendar, now: now) {} else {
            Issue.record("a calendar error fails the load")
        }
    }

    // MARK: declarations

    @MainActor
    @Test("the Recording widget declares the recordings MCP, and only start and stop change data")
    func recordingsDeclaration() throws {
        let mcps = RecordingWidget().mcpTools
        #expect(mcps.map(\.id) == ["recordings"])
        let tools = try #require(mcps.first).tools
        #expect(tools.map(\.id) == ["recording_status", "start_recording", "stop_recording", "read_transcript"])
        #expect(tools.filter(\.changesData).map(\.id) == ["start_recording", "stop_recording"])
        #expect(tools.last?.input.properties["limit"]?.isRequired == false)
    }

    @MainActor
    @Test("the Event session type declares the calendar MCP with get_event and list_events, both read-only")
    func calendarDeclaration() throws {
        let mcps = EventSessionType().mcpTools
        #expect(mcps.map(\.id) == ["calendar"])
        let tools = try #require(mcps.first).tools
        #expect(tools.map(\.id) == ["get_event", "list_events"])
        #expect(tools.allSatisfy { !$0.changesData })
    }
}
