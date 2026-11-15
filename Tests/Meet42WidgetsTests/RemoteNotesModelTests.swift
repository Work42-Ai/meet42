// RemoteNotesModelTests.swift — My Notes on a device that is not the Mac: read through the file service, saved through
// `meet42 notes write`, and never replacing what the person is typing.

import Foundation
import Testing
import Work42PluginKit
@testable import Meet42AnnotationsWidget

/// A Mac: it holds the notes file, answers the file service, and runs `meet42 notes write --base64 '<payload>'` the way the
/// CLI does. The test drives it from outside (a change made on the Mac, a failing save, a slow save).
private nonisolated final class FakeMac: WidgetShellService, WidgetFileService, @unchecked Sendable {
    private let lock = NSLock()
    private var file: String?
    private var commandsRun: [String] = []
    private var failures = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var ticks: [AsyncStream<Void>.Continuation] = []

    init(notes: String? = nil) { file = notes }

    var notes: String? { lock.withLock { file } }
    var commands: [String] { lock.withLock { commandsRun } }

    /// Someone else changes the notes on the Mac (its own widget): the file service reports it.
    func changeOnMac(_ text: String) {
        let watchers = lock.withLock { () -> [AsyncStream<Void>.Continuation] in file = text; return ticks }
        watchers.forEach { $0.yield() }
    }

    func failNextSaves(_ count: Int) { lock.withLock { failures = count } }
    /// The next save waits until `release()`.
    func holdNextSave() { lock.withLock { holdNext = true } }
    func release() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }?.resume() }

    // MARK: WidgetFileService

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

    // MARK: WidgetShellService

    func run(command: String) async throws -> WidgetShellResult {
        let (shouldHold, shouldFail) = lock.withLock { () -> (Bool, Bool) in
            commandsRun.append(command)
            defer { holdNext = false; if failures > 0 { failures -= 1 } }
            return (holdNext, failures > 0)
        }
        if shouldHold { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        if shouldFail { return WidgetShellResult(stdout: "", stderr: "meet42 notes write: disk is full\n", exitCode: 1) }
        let prefix = "meet42 notes write --base64 '"
        guard command.hasPrefix(prefix), command.hasSuffix("'"),
              let data = Data(base64Encoded: String(command.dropFirst(prefix.count).dropLast())),
              let text = String(data: data, encoding: .utf8)
        else { return WidgetShellResult(stdout: "", stderr: "unknown command", exitCode: 2) }
        lock.withLock { file = text }
        return WidgetShellResult(stdout: "wrote \(data.count) bytes\n", stderr: "", exitCode: 0)
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

@Suite("My Notes on another device")
@MainActor
struct RemoteNotesModelTests {

    private func model(_ mac: FakeMac) -> RemoteNotesModel {
        let services = SessionServices(
            composer: StubComposer(), shell: mac, intents: StubIntents(), storage: StubStorage(), pill: StubPill(),
            files: mac, sessionId: "s1")
        let model = RemoteNotesModel(services: services)
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
        let empty = model(FakeMac())
        await empty.load()
        #expect(empty.loaded && empty.text == "" && empty.failure == nil)

        let filled = model(FakeMac(notes: "agenda\n- budget"))
        await filled.load()
        #expect(filled.text == "agenda\n- budget" && !filled.isDirty)
    }

    @Test("typing is saved on the Mac once it pauses, through the notes verb")
    func saves() async throws {
        let mac = FakeMac()
        let model = model(mac)
        await model.load()
        model.text = "call Ada"
        model.textChanged()
        try await eventually("the save") { model.saveState == .saved }
        #expect(mac.notes == "call Ada")
        #expect(!model.isDirty)
        let payload = Data("call Ada".utf8).base64EncodedString()
        #expect(mac.commands == ["meet42 notes write --base64 '\(payload)'"])
    }

    @Test("quotes, line breaks, shell characters and non-ASCII text reach the Mac exactly")
    func awkwardText() async throws {
        let mac = FakeMac()
        let model = model(mac)
        await model.load()
        let note = "It's \"Q3\"; $HOME `ls` | & > < ( )\n\n- caf\u{00E9} ✅\n"
        model.text = note
        await model.save()
        #expect(mac.notes == note)
        // The command itself carries none of those characters: only base64 inside quotes.
        let command = try #require(mac.commands.first)
        #expect(command.dropFirst("meet42 notes write --base64 '".count).dropLast().allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
    }

    @Test("a change made on the Mac shows up while nothing here is unsaved")
    func followsTheMac() async throws {
        let mac = FakeMac(notes: "one")
        let model = model(mac)
        let following = Task { await model.follow() }
        defer { following.cancel() }
        try await eventually("the first read") { model.loaded }
        try await Task.sleep(for: .milliseconds(30))   // the watch is open
        mac.changeOnMac("one, edited on the Mac")
        try await eventually("the change") { model.text == "one, edited on the Mac" }
        #expect(!model.isDirty)
    }

    @Test("a change made on the Mac never replaces what is being typed here")
    func doesNotClobberTyping() async throws {
        let mac = FakeMac(notes: "one")
        let model = model(mac)
        await model.load()
        model.text = "one and my own words"          // typed, not saved yet
        mac.changeOnMac("one, edited on the Mac")
        await model.load()
        #expect(model.text == "one and my own words")
        #expect(model.isDirty)
    }

    @Test("a save the Mac refuses keeps the text, says so, and the next edit tries again")
    func failedSave() async throws {
        let mac = FakeMac()
        mac.failNextSaves(1)
        let model = model(mac)
        await model.load()
        model.text = "keep this"
        await model.save()
        guard case .failed(let reason) = model.saveState else { Issue.record("expected a failure, got \(model.saveState)"); return }
        #expect(reason.contains("disk is full"))
        #expect(model.text == "keep this" && model.isDirty && mac.notes == nil)

        model.text = "keep this, edited"
        model.textChanged()
        try await eventually("the retry") { model.saveState == .saved }
        #expect(mac.notes == "keep this, edited")
    }

    @Test("a note too long for one command is not sent, and the text stays")
    func tooLong() async throws {
        let mac = FakeMac()
        let model = model(mac)
        await model.load()
        model.text = String(repeating: "a", count: 400_000)
        await model.save()
        guard case .failed(let reason) = model.saveState else { Issue.record("expected a failure"); return }
        #expect(reason.contains("too long"))
        #expect(mac.commands.isEmpty && model.text.count == 400_000)
    }

    @Test("typing during a slow save is saved afterwards, and the last text wins")
    func editDuringSave() async throws {
        let mac = FakeMac()
        let model = model(mac)
        await model.load()
        mac.holdNextSave()
        model.text = "first"
        let saving = Task { await model.save() }
        try await eventually("the save to start") { mac.commands.count == 1 }
        model.text = "first, then more"
        model.textChanged()
        mac.release()
        await saving.value
        try await eventually("the later text") { mac.notes == "first, then more" && model.saveState == .saved }
        #expect(!model.isDirty)
    }
}
