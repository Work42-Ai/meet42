// MeetingRecorder.swift — recording a meeting through Work42's audio and speech services.
//
// meet42 used to record with a daemon of its own (`meet42 record start`), which held the microphone, system-audio and speech
// permissions. macOS does not give those to an extension, so Work42 holds them and records for the plugin (SDK 3.3.0):
// `services.audio` writes a file per source (microphone, system audio) and `services.speech` turns the live audio into text.
// This type is the one thing in the extension that owns a recording, so the Recording tile, the calendar's auto-record and an
// agent all go through it:
//
//   • start(...)   begins capture into ~/.work42/meet42/recordings/<recordingId>/ and the transcript, and takes the machine's one
//                  recording slot: a second start is refused, never queued (what `record start` did).
//   • stop(...)    ends capture, lets the transcript finish and gives the slot back.
//   • isRecording(dir:) is the truth every surface reads ("is MY session's recording the one running"), replacing
//                  `meet42 record status`.
//
// The transcript is written to `conversation.jsonl` in the same line shape the old engine wrote (`ts`, `speaker` You/Them,
// `text`, `audioStartSeconds`/`audioEndSeconds`, `lineId`), so the tile, `meet42 transcript` and the summary skill read it as
// before. The microphone side is "You" and the system audio is "Them". Voices within "Them" are not told apart (the speaker
// diarization the old daemon ran is not part of Work42's speech service); a name is still given to "Them" afterwards through
// `speakers.json`, as before.
//
// A recording lives as long as the scope that started it. A tile's scope ends when the tile leaves the screen, so a recording
// is started from a background agent's services whenever the session has one (an agent's scope lasts as long as the session is
// alive); only a session with no agent running falls back to the tile's own.

import Foundation
import Work42PluginKit

/// The services a recording needs, from a background agent or, failing that, a tile.
struct RecorderServices {
    let audio: any WidgetAudioService
    let speech: any WidgetSpeechService
    /// Where the recording is owned: a tile's recording ends when the tile leaves the screen.
    let ownedByAgent: Bool

    @MainActor init(background: WidgetBackgroundServices) {
        audio = background.audio
        speech = background.speech
        ownedByAgent = true
    }

    @MainActor init(session: SessionServices) {
        audio = session.audio
        speech = session.speech
        ownedByAgent = false
    }

    init(audio: any WidgetAudioService, speech: any WidgetSpeechService, ownedByAgent: Bool = true) {
        self.audio = audio
        self.speech = speech
        self.ownedByAgent = ownedByAgent
    }
}

/// What a start came to.
enum MeetingRecordStart {
    case started(recordingId: String, dir: String)
    /// Another recording holds the slot.
    case refused(owner: String)
    /// Capture could not start. `reason` is one of `microphone_denied`, `system_audio_denied`, `microphone_unavailable`,
    /// `capture_failed`; `message` is what to tell the person.
    case failed(reason: String, message: String)
}

@MainActor
final class MeetingRecorder {

    static let shared = MeetingRecorder()

    /// The recording that holds the slot.
    struct Active: Equatable {
        let recordingId: String
        let dir: String
        let app: String
        let bundleId: String
        let startedAt: Date
    }

    private(set) var active: Active?

    /// Background services by session, registered by the agents that run for it: a recording started from a tile borrows its
    /// session's agent, so it outlives the tile.
    private var agents: [String: WidgetBackgroundServices] = [:]

    private let folder: URL
    /// The folder as a recording request names it (`~/...`), which Work42 resolves against the plugin's declared folders.
    private let requestFolder: String

    private var running: Running?

    /// How long `stop` waits for the transcript to finish its last words.
    var transcriptGrace: Duration = .seconds(6)

    init(folder: URL = RealHome.meet42Folder, requestFolder: String = "~/.work42/meet42") {
        self.folder = folder
        self.requestFolder = requestFolder
    }

    private final class Running {
        let recording: AudioRecording
        let writer: ConversationWriter
        var levels: Task<Void, Never>?
        var transcript: Task<Void, Never>?

        init(recording: AudioRecording, writer: ConversationWriter) {
            self.recording = recording
            self.writer = writer
        }
    }

    // MARK: Agents

    /// An agent for `sessionId` is running; recordings started from that session's tiles belong to it.
    func register(sessionId: String, services: WidgetBackgroundServices) {
        agents[sessionId] = services
    }

    func unregister(sessionId: String) {
        agents[sessionId] = nil
    }

    /// The services to record with for `session`: its agent's when it has one, else the tile's own.
    func services(for session: SessionServices) -> RecorderServices {
        if let sessionId = session.sessionId, let agent = agents[sessionId] { return RecorderServices(background: agent) }
        return RecorderServices(session: session)
    }

    // MARK: Status

    func isRecording(dir: String?) -> Bool {
        guard let active else { return false }
        guard let dir else { return true }
        return Self.sameFolder(active.dir, dir)
    }

    static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    // MARK: Start

    /// Starts capturing both sides of a meeting and the transcript. The slot is taken only once capture has really started.
    func start(services: RecorderServices, app: String, bundleId: String, now: Date = Date()) async -> MeetingRecordStart {
        if let active {
            Meet42Trace.log("record", "start-refused", ["reason": "already-recording", "owner": active.recordingId])
            return .refused(owner: active.recordingId)
        }
        // Held from here, so a second press while this one waits for a permission prompt is refused too.
        let recordingId = UUID().uuidString
        let dir = folder.appendingPathComponent("recordings/\(recordingId)", isDirectory: true).path
        let pending = Active(recordingId: recordingId, dir: dir, app: app, bundleId: bundleId, startedAt: now)
        active = pending

        let request = AudioRecordingRequest(
            sources: [.microphone, .systemAudio], directory: "\(requestFolder)/recordings/\(recordingId)",
            microphoneDevice: Self.selectedMicrophone(in: folder))
        let recording: AudioRecording
        do {
            recording = try await services.audio.startRecording(request)
        } catch {
            active = nil
            let failure = Self.failure(for: error)
            Meet42Trace.log("record", "start-failed", ["reason": failure.reason, "message": failure.message])
            return .failed(reason: failure.reason, message: failure.message)
        }

        let writer = ConversationWriter(file: URL(fileURLWithPath: dir).appendingPathComponent("conversation.jsonl"))
        let state = Running(recording: recording, writer: writer)
        running = state
        // Reading the levels is what keeps the recording alive on Work42's side: a consumer that stops reading ends it.
        state.levels = Task { [weak self] in
            for await _ in recording.levels {}
            self?.captureEnded(recordingId: recordingId)
        }
        state.transcript = Task {
            // Transcription failing (the speech permission, the on-device model) does not end the recording: the audio is
            // still being kept, as it was when the daemon's transcription failed to start.
            do {
                // Partial lines go beside the conversation (the tile shows them as they grow); only a final line is kept in it.
                for try await segment in services.speech.liveTranscript(of: recording.id, partialResults: true) {
                    if segment.isFinal { writer.append(segment) } else { writer.setPartial(segment) }
                }
            } catch {
                Meet42Trace.log("record", "transcription-failed", ["error": String(describing: error)])
            }
        }
        Meet42Trace.log("record", "start-claimed", ["recordingId": recordingId, "app": app, "agent": services.ownedByAgent])
        return .started(recordingId: recordingId, dir: dir)
    }

    // MARK: Stop

    /// Ends the recording in `dir` (or whichever is running when `dir` is nil). Returns false when none matches.
    @discardableResult
    func stop(dir: String? = nil) async -> Bool {
        guard let active, let state = running, dir == nil || Self.sameFolder(active.dir, dir ?? "") else { return false }
        // Out of the way first, so a second stop (the pill and the tile pressed together) finds nothing to end.
        running = nil
        self.active = nil
        do {
            _ = try await state.recording.stop()
        } catch {
            Meet42Trace.log("record", "stop-error", ["error": String(describing: error)])
        }
        state.levels?.cancel()
        // The last words are still being recognized when capture ends: give them a moment, then let go.
        await Self.finish(state.transcript, within: transcriptGrace)
        state.writer.clearAllPartials()
        Meet42Trace.log("record", "stop-finalized", ["recordingId": active.recordingId])
        return true
    }

    /// Capture ended without a stop from here (Work42 quit, the agent's session went away, a permission was withdrawn).
    private func captureEnded(recordingId: String) {
        guard let active, active.recordingId == recordingId else { return }
        running?.transcript?.cancel()
        running = nil
        self.active = nil
        Meet42Trace.log("record", "capture-ended", ["recordingId": recordingId])
    }

    /// Waits for `task` to end, but no longer than `grace`, then cancels it. A race, not a task group: a group would wait for the
    /// losing child on its way out, and a child waiting on `task` does not end when cancelled, so a transcript that never ends
    /// would hold Stop forever.
    private static func finish(_ task: Task<Void, Never>?, within grace: Duration) async {
        guard let task else { return }
        let (done, signal) = AsyncStream<Void>.makeStream()
        Task { await task.value; signal.yield(); signal.finish() }
        Task { try? await Task.sleep(for: grace); signal.yield(); signal.finish() }
        for await _ in done { break }
        task.cancel()
    }

    // MARK: Helpers

    /// The microphone the person chose in the tile's picker (`meet42 mics select`), or nil for the system default.
    static func selectedMicrophone(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("mic-input-device.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let uid = object["uid"] as? String, !uid.isEmpty else { return nil }
        return uid
    }

    /// Maps a failed start to the reasons the tile knows.
    static func failure(for error: any Error) -> (reason: String, message: String) {
        if let permission = error as? PluginPermissionError {
            switch permission {
            case .denied(.microphone, let message): return ("microphone_denied", message)
            case .denied(.systemAudio, let message): return ("system_audio_denied", message)
            case .denied(_, let message): return ("capture_failed", message)
            case .notDeclared: return ("capture_failed", permission.errorDescription ?? "meet42 does not declare the permission it needs.")
            @unknown default: return ("capture_failed", permission.errorDescription ?? "meet42 may not use that permission.")
            }
        }
        let message = (error as? WidgetServiceError)?.errorDescription ?? error.localizedDescription
        if message.lowercased().contains("input device") || message.lowercased().contains("microphone could not") {
            return ("microphone_unavailable", message)
        }
        return ("capture_failed", message)
    }
}

// MARK: - ConversationWriter

/// Appends the transcript to `conversation.jsonl`, one JSON line per finished segment, in the shape the Recording tile and
/// `meet42 transcript` read. One `write` per line, so a reader never sees half a line.
final class ConversationWriter: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(file: URL) { self.file = file }

    /// The line for `segment`, as it is written. `ts` is when the segment finished, as the old engine wrote it.
    func line(for segment: TranscriptSegment, at date: Date = Date(), id: UUID = UUID()) -> String? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let row: [String: Any] = [
            "ts": formatter.string(from: date),
            "speaker": segment.source == .systemAudio ? "Them" : "You",
            "text": text,
            "audioStartSeconds": segment.start,
            "audioEndSeconds": segment.end,
            "lineId": id.uuidString,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json + "\n"
    }

    /// The words still being recognized, one per source, in `partial.json` beside the conversation (an array of lines in the
    /// conversation's shape, with a fixed `lineId` per source so the tile replaces it in place). Never part of the
    /// conversation: `meet42 transcript` and the summary read only finished lines.
    nonisolated static let partialFileName = "partial.json"
    private var partials: [String: [String: Any]] = [:]
    private var partialFile: URL { file.deletingLastPathComponent().appendingPathComponent(Self.partialFileName) }

    func setPartial(_ segment: TranscriptSegment, at date: Date = Date()) {
        guard let line = line(for: segment, at: date, id: UUID()),
              let data = line.data(using: .utf8),
              var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let key = segment.source == .systemAudio ? "Them" : "You"
        row["lineId"] = "partial-\(key)"
        lock.withLock {
            partials[key] = row
            writePartials()
        }
    }

    /// A finished line replaces the partial of its source.
    func clearPartial(for source: AudioSource?) {
        let key = source == .systemAudio ? "Them" : "You"
        lock.withLock {
            guard partials.removeValue(forKey: key) != nil else { return }
            writePartials()
        }
    }

    func clearAllPartials() {
        lock.withLock {
            partials = [:]
            try? FileManager.default.removeItem(at: partialFile)
        }
    }

    /// Callers hold `lock`.
    private func writePartials() {
        if partials.isEmpty {
            try? FileManager.default.removeItem(at: partialFile)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: Array(partials.values), options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: partialFile, options: .atomic)
    }

    func append(_ segment: TranscriptSegment) {
        clearPartial(for: segment.source)
        guard let line = line(for: segment) else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(file.path, O_APPEND | O_CREAT | O_WRONLY, 0o644)
            guard descriptor >= 0 else { return }
            line.withCString { _ = write(descriptor, $0, strlen($0)) }
            close(descriptor)
        }
    }
}
