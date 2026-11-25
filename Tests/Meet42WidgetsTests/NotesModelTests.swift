// NotesModelTests.swift — My Notes: read and followed through the file service, saved by writing the file back through it,
// and never replacing what the person is typing.

import Foundation
import Testing
import Work42PluginKit
@testable import Meet42PluginWidgets

/// A session folder: it holds the notes file and answers the file service. The test drives it from outside (a change made by the
/// agent, a failing write, a slow write).
private nonisolated final class FakeFolder: WidgetFileService, @unchecked Sendable {
    private let lock = NSLock()
    private var file: String?
    private var writesDone: [String] = []
    private var failures = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var ticks: [AsyncStream<Void>.Continuation] = []

    init(notes: String? = nil) { file = notes }

    var notes: String? { lock.withLock { file } }
    var writes: [String] { lock.withLock { writesDone } }

    /// Someone else changes the notes (the agent): the file service reports it.
    func changeElsewhere(_ text: String) {
        let watchers = lock.withLock { () -> [AsyncStream<Void>.Continuation] in file = text; return ticks }
        watchers.forEach { $0.yield() }
    }

    func failNextWrites(_ count: Int) { lock.withLock { failures = count } }
    /// The next write waits until `release()`.
    func holdNextWrite() { lock.withLock { holdNext = true } }
    func release() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }?.resume() }

    func read(_ relativePath: String) async throws -> Data {
        guard let text = lock.withLock({ file }) else {
            throw WidgetServiceError(message: "no such file: \(relativePath)", suggestion: nil)
        }
        return Data(text.utf8)
    }

    func list(_ relativeDir: String) async throws -> [WidgetFileEntry] { [] }

    func watch(_ relativePath: String) -> AsyncStream<Void> {
        AsyncStream { continuation in lock.withLock { ticks.append(continuation) } }
    }

    func write(_ relativePath: String, data: Data) async throws {
        let (shouldHold, shouldFail) = lock.withLock { () -> (Bool, Bool) in
            writesDone.append(relativePath)
            defer { holdNext = false; if failures > 0 { failures -= 1 } }
            return (holdNext, failures > 0)
        }
        if shouldHold { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        if shouldFail { throw WidgetServiceError(message: "disk is full", suggestion: nil) }
        lock.withLock { file = String(decoding: data, as: UTF8.self) }
    }

    func remove(_ relativePath: String) async throws {}
}

private struct StubShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "", stderr: "not expected: \(command)", exitCode: 1)
    }
}

private struct StubComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
}

private struct StubIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct StubStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct StubPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

@Suite("My Notes")
@MainActor
struct NotesModelTests {

    private func model(_ folder: FakeFolder) -> NotesModel {
        let services = SessionServices(
            composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill(),
            files: folder, sessionId: "s1")
        let model = NotesModel(services: services)
        model.debounce = .milliseconds(30)
        return model
    }

    private func eventually(_ what: String = "", _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    @Test("a notes file that is not there yet is the empty state; one that is there is shown")
    func loads() async throws {
        let empty = model(FakeFolder())
        await empty.load()
        #expect(empty.loaded && empty.text == "" && empty.failure == nil)

        let filled = model(FakeFolder(notes: "agenda\n- budget"))
        await filled.load()
        #expect(filled.text == "agenda\n- budget" && !filled.isDirty)
    }

    @Test("typing is saved once it pauses, by writing annotations.md through the file service")
    func saves() async throws {
        let folder = FakeFolder()
        let model = model(folder)
        await model.load()
        model.text = "call Ada"
        model.textChanged()
        try await eventually("the save") { model.saveState == .saved }
        #expect(folder.notes == "call Ada")
        #expect(!model.isDirty)
        #expect(folder.writes == ["annotations.md"])
    }

    @Test("quotes, line breaks, shell characters and non-ASCII text are written exactly, and a long note is no problem")
    func awkwardText() async throws {
        let folder = FakeFolder()
        let model = model(folder)
        await model.load()
        let note = "It's \"Q3\"; $HOME `ls` | & > < ( )\n\n- caf\u{00E9} ✅\n" + String(repeating: "a", count: 500_000)
        model.text = note
        await model.save()
        #expect(folder.notes == note)
        #expect(model.saveState == .saved)
    }

    @Test("a change made elsewhere shows up while nothing here is unsaved")
    func followsTheFolder() async throws {
        let folder = FakeFolder(notes: "one")
        let model = model(folder)
        let following = Task { await model.follow() }
        defer { following.cancel() }
        try await eventually("the first read") { model.loaded }
        try await Task.sleep(for: .milliseconds(30))   // the watch is open
        folder.changeElsewhere("one, edited by the agent")
        try await eventually("the change") { model.text == "one, edited by the agent" }
        #expect(!model.isDirty)
    }

    @Test("a change made elsewhere never replaces what is being typed here")
    func doesNotClobberTyping() async throws {
        let folder = FakeFolder(notes: "one")
        let model = model(folder)
        await model.load()
        model.text = "one and my own words"          // typed, not saved yet
        folder.changeElsewhere("one, edited by the agent")
        await model.load()
        #expect(model.text == "one and my own words")
        #expect(model.isDirty)
    }

    @Test("a save that is refused keeps the text, says so, and the next edit tries again")
    func failedSave() async throws {
        let folder = FakeFolder()
        folder.failNextWrites(1)
        let model = model(folder)
        await model.load()
        model.text = "keep this"
        await model.save()
        guard case .failed(let reason) = model.saveState else { Issue.record("expected a failure, got \(model.saveState)"); return }
        #expect(reason.contains("disk is full"))
        #expect(model.text == "keep this" && model.isDirty && folder.notes == nil)

        model.text = "keep this, edited"
        model.textChanged()
        try await eventually("the retry") { model.saveState == .saved }
        #expect(folder.notes == "keep this, edited")
    }

    @Test("typing during a slow save is saved afterwards, and the last text wins")
    func editDuringSave() async throws {
        let folder = FakeFolder()
        let model = model(folder)
        await model.load()
        folder.holdNextWrite()
        model.text = "first"
        let saving = Task { await model.save() }
        try await eventually("the save to start") { folder.writes.count == 1 }
        model.text = "first, then more"
        model.textChanged()
        folder.release()
        await saving.value
        try await eventually("the later text") { folder.notes == "first, then more" && model.saveState == .saved }
        #expect(!model.isDirty)
    }
}
