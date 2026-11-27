// MeetingRecorderTests.swift — a recording through Work42's audio and speech services: one at a time, a file per source, the
// transcript in the shape the tile reads, and a clean end however it ends.

import Foundation
import Testing
import Work42PluginKit
@testable import Meet42PluginWidgets

/// Work42's audio and speech services, scripted by the test.
private nonisolated final class FakeWork42: WidgetAudioService, WidgetSpeechService, @unchecked Sendable {
    private let lock = NSLock()
    private var startRequests: [AudioRecordingRequest] = []
    private var stops = 0
    private var levelsEnd: AsyncStream<AudioLevels>.Continuation?
    private var transcriptEnd: AsyncThrowingStream<TranscriptSegment, any Error>.Continuation?
    private var liveOf: UUID?
    private var recordingId = UUID()
    var startFailure: (any Error)?
    var transcriptFailure: (any Error)?

    var requests: [AudioRecordingRequest] { lock.withLock { startRequests } }
    var stopCount: Int { lock.withLock { stops } }
    var transcribedRecording: UUID? { lock.withLock { liveOf } }
    var hostRecordingId: UUID { lock.withLock { recordingId } }

    func startRecording(_ request: AudioRecordingRequest) async throws -> AudioRecording {
        if let startFailure { throw startFailure }
        let (levels, continuation) = AsyncStream<AudioLevels>.makeStream()
        let id = UUID()
        lock.withLock { startRequests.append(request); levelsEnd = continuation; recordingId = id }
        continuation.yield(AudioLevels(source: .microphone, level: 0.4))
        return AudioRecording(id: id, levels: levels, stop: { [weak self] in
            self?.lock.withLock { self?.stops += 1 }
            continuation.finish()
            self?.finishTranscript()
            return [URL(fileURLWithPath: "/tmp/microphone.caf"), URL(fileURLWithPath: "/tmp/system-audio.caf")]
        })
    }

    func liveTranscript(of recording: UUID) -> AsyncThrowingStream<TranscriptSegment, any Error> {
        lock.withLock { liveOf = recording }
        if let transcriptFailure {
            return AsyncThrowingStream { $0.finish(throwing: transcriptFailure) }
        }
        return AsyncThrowingStream { continuation in lock.withLock { transcriptEnd = continuation } }
    }

    /// A finished piece of speech arrives.
    func say(_ text: String, from source: AudioSource, start: Double = 0, end: Double = 1) {
        let continuation = lock.withLock { transcriptEnd }
        continuation?.yield(TranscriptSegment(start: start, end: end, text: text, source: source))
    }

    func finishTranscript() { lock.withLock { transcriptEnd }?.finish() }

    /// Work42 ends the capture without being asked (it quit, the agent's session went away).
    func endCapture() {
        lock.withLock { levelsEnd }?.finish()
        finishTranscript()
    }

    @MainActor var services: RecorderServices { RecorderServices(audio: self, speech: self) }
}

@Suite("MeetingRecorder", .serialized)
@MainActor
struct MeetingRecorderTests {

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meet42-rec-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recorder(_ folder: URL) -> MeetingRecorder {
        let recorder = MeetingRecorder(folder: folder, requestFolder: "~/.work42/meet42")
        recorder.transcriptGrace = .milliseconds(300)
        return recorder
    }

    private func eventually(_ what: String = "", _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func lines(in dir: String) throws -> [String] {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("conversation.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: Start

    @Test("a start records both sides into the recording's own folder, and takes the slot")
    func starts() async throws {
        let work42 = FakeWork42()
        let folder = folder()
        let recorder = recorder(folder)
        let outcome = await recorder.start(services: work42.services, app: "Zoom", bundleId: "us.zoom.xos")
        guard case .started(let id, let dir) = outcome else { Issue.record("expected a start, got \(outcome)"); return }

        let request = try #require(work42.requests.first)
        #expect(request.sources == [.microphone, .systemAudio])
        #expect(request.directory == "~/.work42/meet42/recordings/\(id)")
        #expect(dir == folder.appendingPathComponent("recordings/\(id)").path)
        #expect(request.microphoneDevice == nil)
        #expect(recorder.isRecording(dir: dir) && recorder.isRecording(dir: nil))
        #expect(recorder.active?.app == "Zoom" && recorder.active?.bundleId == "us.zoom.xos")
        await recorder.stop()
    }

    @Test("the microphone chosen in the tile's picker is the one recorded")
    func choosesTheMicrophone() async throws {
        let work42 = FakeWork42()
        let folder = folder()
        try Data(#"{"uid":"AppleUSBAudioEngine:1234","name":"USB mic"}"#.utf8).write(to: folder.appendingPathComponent("mic-input-device.json"))
        let recorder = recorder(folder)
        _ = await recorder.start(services: work42.services, app: "Manual", bundleId: "")
        #expect(work42.requests.first?.microphoneDevice == "AppleUSBAudioEngine:1234")
        await recorder.stop()
    }

    @Test("a second start is refused while one runs, never queued, and works once the first has stopped")
    func oneAtATime() async throws {
        let work42 = FakeWork42()
        let recorder = recorder(folder())
        guard case .started(let first, let dir) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("the first start failed"); return
        }
        guard case .refused(let owner) = await recorder.start(services: work42.services, app: "Zoom", bundleId: "x") else {
            Issue.record("the second start was not refused"); return
        }
        #expect(owner == first)
        #expect(work42.requests.count == 1)

        #expect(await recorder.stop(dir: dir))
        guard case .started = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("a start after the stop failed"); return
        }
        await recorder.stop()
    }

    @Test("a refused permission is reported with the reason the tile knows, and gives the slot back")
    func permissionFailures() async throws {
        let work42 = FakeWork42()
        let recorder = recorder(folder())

        work42.startFailure = PluginPermissionError.denied(.systemAudio, message: "System audio is off for Work42.")
        guard case .failed(let reason, let message) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("expected a failure"); return
        }
        #expect(reason == "system_audio_denied" && message == "System audio is off for Work42.")
        #expect(recorder.active == nil)

        work42.startFailure = PluginPermissionError.denied(.microphone, message: "No microphone for you.")
        if case .failed(let reason, _) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") {
            #expect(reason == "microphone_denied")
        } else { Issue.record("expected a failure") }

        work42.startFailure = WidgetServiceError(message: "The microphone could not be started: this Mac has no input device")
        if case .failed(let reason, _) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") {
            #expect(reason == "microphone_unavailable")
        } else { Issue.record("expected a failure") }

        work42.startFailure = WidgetServiceError(message: "disk full")
        if case .failed(let reason, let message) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") {
            #expect(reason == "capture_failed" && message.contains("disk full"))
        } else { Issue.record("expected a failure") }

        work42.startFailure = nil
        guard case .started = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("a start after the failures failed"); return
        }
        await recorder.stop()
    }

    // MARK: Transcript

    @Test("the transcript is written as the tile reads it: microphone is You, system audio is Them")
    func writesTheTranscript() async throws {
        let work42 = FakeWork42()
        let recorder = recorder(folder())
        guard case .started(_, let dir) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("the start failed"); return
        }
        try await eventually("the live transcript to open") { work42.transcribedRecording != nil }
        #expect(work42.transcribedRecording == work42.hostRecordingId)
        work42.say("Hello team", from: .microphone, start: 0.5, end: 1.5)
        work42.say("Hi, can you hear me?", from: .systemAudio, start: 2, end: 3.25)
        work42.say("   ", from: .microphone)   // nothing said: not written
        try await eventually("both lines") { (try? lines(in: dir).count) == 2 }

        let parsed = try lines(in: dir).compactMap { RecordingLine(jsonString: $0) }
        guard case .speaker(let you) = parsed[0], case .speaker(let them) = parsed[1] else { Issue.record("expected speaker lines"); return }
        #expect(you.speaker == .you && you.text == "Hello team" && them.speaker == .them && them.text == "Hi, can you hear me?")
        #expect(you.persistentId != nil && you.persistentId != them.persistentId)
        #expect(you.date != nil)

        let object = try #require(JSONSerialization.jsonObject(with: Data(try lines(in: dir)[1].utf8)) as? [String: Any])
        #expect(object["audioStartSeconds"] as? Double == 2 && object["audioEndSeconds"] as? Double == 3.25)
        await recorder.stop()
    }

    @Test("words said just before Stop are on disk when Stop returns")
    func stopKeepsTheLastWords() async throws {
        let work42 = FakeWork42()
        let recorder = recorder(folder())
        guard case .started(_, let dir) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("the start failed"); return
        }
        try await eventually("the live transcript to open") { work42.transcribedRecording != nil }
        work42.say("last words", from: .systemAudio)
        #expect(await recorder.stop(dir: dir))
        #expect(try lines(in: dir).count == 1)
        #expect(work42.stopCount == 1)
    }

    @Test("a transcript that cannot run does not end the recording")
    func transcriptFailureKeepsRecording() async throws {
        let work42 = FakeWork42()
        work42.transcriptFailure = PluginPermissionError.denied(.speechRecognition, message: "Speech recognition is off.")
        let recorder = recorder(folder())
        guard case .started(_, let dir) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("the start failed"); return
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.isRecording(dir: dir))
        #expect(work42.stopCount == 0)
        await recorder.stop()
    }

    // MARK: Stop

    @Test("stop names its recording: another folder stops nothing, and nothing running is not an error")
    func stopNamesItsRecording() async throws {
        let work42 = FakeWork42()
        let recorder = recorder(folder())
        #expect(await recorder.stop() == false)
        guard case .started(_, let dir) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("the start failed"); return
        }
        #expect(await recorder.stop(dir: "/somewhere/else") == false)
        #expect(recorder.isRecording(dir: dir))
        #expect(!recorder.isRecording(dir: "/somewhere/else"))
        #expect(await recorder.stop(dir: dir))
        #expect(!recorder.isRecording(dir: nil))
        #expect(await recorder.stop(dir: dir) == false)
    }

    @Test("a capture Work42 ends by itself gives the slot back")
    func captureEndsOnItsOwn() async throws {
        let work42 = FakeWork42()
        let recorder = recorder(folder())
        guard case .started(_, let dir) = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("the start failed"); return
        }
        work42.endCapture()
        try await eventually("the slot to be released") { !recorder.isRecording(dir: dir) }
        guard case .started = await recorder.start(services: work42.services, app: "Manual", bundleId: "") else {
            Issue.record("a start after the capture ended failed"); return
        }
        await recorder.stop()
    }

    // MARK: Which services

    @Test("a session without an agent records with its tile's services; one with an agent records with the agent's")
    func chooseServices() {
        let recorder = recorder(folder())
        let agent = WidgetBackgroundServices(shell: NullShell(), storage: NullStorage(), pill: NullPill(), sessionId: "s1", taskId: nil)
        let tile = SessionServices(composer: NullComposer(), shell: NullShell(), intents: NullIntents(), storage: NullStorage(),
                                   pill: NullPill(), sessionId: "s1")
        #expect(recorder.services(for: tile).ownedByAgent == false)
        recorder.register(sessionId: "s1", services: agent)
        #expect(recorder.services(for: tile).ownedByAgent == true)
        recorder.unregister(sessionId: "s1")
        #expect(recorder.services(for: tile).ownedByAgent == false)
    }
}

// MARK: - Stubs

private struct NullShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult { WidgetShellResult(stdout: "", stderr: "", exitCode: 0) }
}

private struct NullComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
}

private struct NullIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct NullStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct NullPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}
