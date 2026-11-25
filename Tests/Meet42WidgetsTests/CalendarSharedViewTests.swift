// CalendarSharedViewTests.swift — the calendar's view mode and date are shared through the widget's storage, so the Mac's
// action-area controls (which act on the Mac's instance) also move the calendar an iPad draws (its own instance).

import Foundation
import Testing
import Work42PluginKit
@testable import Meet42PluginWidgets

/// One storage for every instance, as the Mac's database is for the Mac's calendar and an iPad's (through the link).
private nonisolated final class SharedStorage: WidgetStorageService, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: WidgetJSONValue] = [:]
    private var delay: Duration = .zero
    private var unavailable = false

    func setReadDelay(_ delay: Duration) { lock.withLock { self.delay = delay } }
    func setUnavailable(_ value: Bool) { lock.withLock { unavailable = value } }

    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? {
        let (value, delay, unavailable) = lock.withLock { (values["\(namespace)/\(key)"], self.delay, self.unavailable) }
        if unavailable { throw WidgetServiceError(message: "no storage on this surface") }
        // The value is taken when the read starts, and handed back after the delay: a slow link.
        if delay > .zero { try await Task.sleep(for: delay) }
        return value
    }

    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }

    nonisolated func set(key: String, value: WidgetJSONValue) async throws {
        lock.withLock { values["calendar/\(key)"] = value }
    }

    nonisolated func delete(key: String) async throws {
        lock.withLock { _ = values.removeValue(forKey: "calendar/\(key)") }
    }

    /// A shared state as another instance would have written it.
    func seed(mode: String, reference: Date, writtenAt: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.withLock {
            values["calendar/view_state"] = .object([
                "mode": .string(mode),
                "reference": .string(formatter.string(from: reference)),
                "written_at": .string(formatter.string(from: writtenAt)),
            ])
        }
    }
}

private struct StubComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
}

/// Every command fails, so a refresh only exercises the shared view and leaves the event list alone.
private struct FailingShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "", stderr: "", exitCode: 1)
    }
}

private struct StubIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct StubPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

@Suite("Calendar shared view")
@MainActor
struct CalendarSharedViewTests {

    private func store(_ storage: SharedStorage) -> CLICalendarStore {
        CLICalendarStore(services: SessionServices(
            composer: StubComposer(), shell: FailingShell(), intents: StubIntents(), storage: storage, pill: StubPill(),
            sessionId: "s1"))
    }

    /// Lets a store's write to storage land.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }

    @Test("a change on one instance moves the other, in both directions")
    func followsEachOther() async throws {
        let storage = SharedStorage()
        let mac = store(storage)
        let ipad = store(storage)
        await mac.refresh()
        await ipad.refresh()   // both start with nothing shared yet

        mac.goToNext()         // the Mac's Next control
        try await settle()
        await ipad.refresh()
        #expect(abs(ipad.referenceDate.timeIntervalSince(mac.referenceDate)) < 0.002)
        #expect(ipad.viewMode == .week)

        mac.setViewMode(.day)  // the Mac's View menu
        try await settle()
        await ipad.refresh()
        #expect(ipad.viewMode == .day)
        #expect(abs(ipad.referenceDate.timeIntervalSince(mac.referenceDate)) < 0.002)

        ipad.goToPrevious()    // and back
        try await settle()
        await mac.refresh()
        #expect(abs(mac.referenceDate.timeIntervalSince(ipad.referenceDate)) < 0.002)
    }

    @Test("a read that began before a tap does not undo the tap")
    func staleReadDoesNotRevert() async throws {
        let storage = SharedStorage()
        let mac = store(storage)
        let ipad = store(storage)
        await mac.refresh()
        await ipad.refresh()
        ipad.setViewMode(.day)
        try await settle()
        await mac.refresh()                       // the Mac adopts Day
        ipad.setViewMode(.agenda)
        try await settle()                        // storage now says Agenda

        storage.setReadDelay(.milliseconds(200))
        let reading = Task { await mac.refresh() }   // reads Agenda, slowly
        try await Task.sleep(for: .milliseconds(60))
        mac.setViewMode(.week)                    // the user taps while that read is in flight
        await reading.value

        #expect(mac.viewMode == .week, "the late answer (Agenda) must not replace the tap")
    }

    @Test("a new instance starts from a state written a moment ago, not from one left long ago")
    func freshness() async throws {
        let now = Date()
        let recent = SharedStorage()
        recent.seed(mode: "day", reference: now.addingTimeInterval(-86_400 * 3), writtenAt: now.addingTimeInterval(-60))
        let a = store(recent)
        await a.refresh()
        #expect(a.viewMode == .day, "another device is showing Day right now")
        #expect(abs(a.referenceDate.timeIntervalSince(now.addingTimeInterval(-86_400 * 3))) < 0.002)

        let old = SharedStorage()
        old.seed(mode: "day", reference: now.addingTimeInterval(-86_400 * 3), writtenAt: now.addingTimeInterval(-3_600))
        let b = store(old)
        await b.refresh()
        #expect(b.viewMode == .week, "a view left an hour ago is not restored: the calendar starts on this week")
        #expect(abs(b.referenceDate.timeIntervalSince(now)) < 5)

        // From then on it follows what someone else does.
        old.seed(mode: "agenda", reference: now, writtenAt: Date())
        await b.refresh()
        #expect(b.viewMode == .agenda)
    }

    @Test("without storage the calendar behaves as it always did")
    func noStorage() async throws {
        let storage = SharedStorage()
        storage.setUnavailable(true)
        let calendar = store(storage)
        await calendar.refresh()
        #expect(calendar.viewMode == .week)

        calendar.setViewMode(.day)
        calendar.goToNext()
        try await settle()
        await calendar.refresh()
        #expect(calendar.viewMode == .day)
    }
}
