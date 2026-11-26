// MeetTools.swift — what an agent can do with meetings, as MCP tools written in Swift (WOR-901).
//
// Two MCPs, both calling the same code the tiles call:
//
//   `recordings` (the Recording widget)   recording_status, start_recording, stop_recording, read_transcript
//                                         They go through `MeetingRecorder.shared`, the one thing in the extension that owns a
//                                         recording, so a recording an agent starts is the recording the tile shows, and the other
//                                         way round. The tile and a tool never disagree about whether one is running.
//   `calendar` (the Event session type)   get_event, list_events
//                                         They read through `services.calendar` (Work42 holds the Calendar permission), not through
//                                         a command line.
//
// The pure parts (how the answers are shaped, how a transcript line is read) are plain functions so they are tested on their own.

import Foundation
import Work42PluginKit

// MARK: - Events as an agent reads them

/// One calendar event, as the tools answer with it. Dates are ISO 8601 text so an agent can read and compare them.
nonisolated struct MeetEventSummary: Codable, Sendable, Equatable {
    struct Attendee: Codable, Sendable, Equatable {
        var name: String?
        var email: String?
        var status: String
        var isOrganizer: Bool
        var isCurrentUser: Bool

        enum CodingKeys: String, CodingKey {
            case name, email, status
            case isOrganizer = "is_organizer"
            case isCurrentUser = "is_current_user"
        }
    }

    var id: String
    var title: String
    var start: String
    var end: String
    var allDay: Bool
    var calendar: String?
    var source: String?
    var status: String?
    var location: String?
    var organizer: String?
    var url: String?
    var notes: String?
    var attendees: [Attendee]

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, calendar, source, status, location, organizer, url, notes, attendees
        case allDay = "all_day"
    }

    init(_ event: CalendarEvent) {
        id = event.id
        title = event.title
        start = Self.iso(event.start)
        end = Self.iso(event.end)
        allDay = event.isAllDay
        calendar = event.calendar
        source = event.source
        status = event.status
        location = event.location
        organizer = event.organizer
        url = event.url
        notes = event.notes
        if let details = event.attendeeDetails {
            attendees = details.map { Attendee(name: $0.name, email: $0.email, status: $0.status, isOrganizer: $0.isOrganizer, isCurrentUser: $0.isCurrentUser) }
        } else {
            attendees = event.attendees.map { Attendee(name: $0, email: nil, status: "unknown", isOrganizer: false, isCurrentUser: false) }
        }
    }

    nonisolated static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// The events of a window, soonest first, at most `limit`, as `list_events` answers.
nonisolated enum MeetEventListing {
    static let defaultSpan: TimeInterval = 7 * 86_400
    static let maxSpan: TimeInterval = 90 * 86_400
    static let maxEvents = 200

    /// The window the arguments name: `from` defaults to `now`, `to` to a week after `from`, and no window is longer than 90 days.
    static func window(from: Date?, to: Date?, now: Date) throws -> (from: Date, to: Date) {
        let start = from ?? now
        let end = to ?? start.addingTimeInterval(defaultSpan)
        guard end > start else {
            throw PluginToolFailure(code: "invalid_arguments", message: "'to' must be after 'from'", suggestion: "pass a 'to' later than 'from'")
        }
        guard end.timeIntervalSince(start) <= maxSpan else {
            throw PluginToolFailure(code: "window_too_long", message: "the window is longer than 90 days",
                                    suggestion: "ask for at most 90 days at a time")
        }
        return (start, end)
    }

    static func summaries(_ events: [CalendarEvent]) -> [MeetEventSummary] {
        events.sorted { $0.start < $1.start }.prefix(maxEvents).map(MeetEventSummary.init)
    }
}

// MARK: - Transcript lines

/// A line of the recording's `conversation.jsonl` as an agent reads it.
nonisolated struct MeetTranscriptLine: Codable, Sendable, Equatable {
    var time: String
    var speaker: String
    var text: String
    var audioStartSeconds: Double?
    var audioEndSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case time, speaker, text
        case audioStartSeconds = "audio_start_seconds"
        case audioEndSeconds = "audio_end_seconds"
    }
}

nonisolated enum MeetTranscript {
    static let defaultLimit = 100
    static let maxLimit = 500

    /// The last `limit` finished lines of a `conversation.jsonl`, oldest first, and how many lines the file holds in all. A line
    /// that is not JSON or has no text is skipped (the file is appended to while it is read).
    static func lines(in data: Data, limit: Int?) -> (lines: [MeetTranscriptLine], total: Int) {
        let wanted = min(max(limit ?? defaultLimit, 1), maxLimit)
        var all: [MeetTranscriptLine] = []
        for raw in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            all.append(MeetTranscriptLine(
                time: object["ts"] as? String ?? "", speaker: object["speaker"] as? String ?? "", text: text,
                audioStartSeconds: object["audioStartSeconds"] as? Double, audioEndSeconds: object["audioEndSeconds"] as? Double))
        }
        return (Array(all.suffix(wanted)), all.count)
    }
}

// MARK: - Answers

nonisolated struct MeetRecordingStatus: Codable, Sendable, Equatable {
    /// Some recording is running on this Mac (there is only ever one).
    var recording: Bool
    /// The running recording is this session's.
    var thisSession: Bool
    var startedAt: String?
    var app: String?
    var recordingDir: String?

    enum CodingKeys: String, CodingKey {
        case recording
        case thisSession = "this_session"
        case startedAt = "started_at"
        case app
        case recordingDir = "recording_dir"
    }
}

nonisolated struct MeetTranscriptAnswer: Codable, Sendable, Equatable {
    var lines: [MeetTranscriptLine]
    /// Lines in the whole transcript; `lines` is the latest of them.
    var total: Int
    var recording: Bool
}

nonisolated struct MeetEventList: Codable, Sendable, Equatable {
    var events: [MeetEventSummary]
}

// MARK: - The recordings MCP (the Recording widget)

extension RecordingWidget: Work42WidgetMCPs {

    var mcpTools: [PluginMCPTools] {
        [
            PluginMCPTools(id: "recordings") {
                PluginTool(id: "recording_status",
                           description: "Whether a meeting is being recorded on this Mac, and whether it is this session's recording.") { _, context in
                    try .structured(await MeetRecordingTools.status(context))
                }
                PluginTool(id: "start_recording",
                           description: "Starts recording this session's meeting: the microphone and the other side of the call, with a live transcript. "
                               + "Only one recording can run on a Mac at a time.",
                           changesData: true) { _, context in
                    try .structured(await MeetRecordingTools.start(context))
                }
                PluginTool(id: "stop_recording",
                           description: "Stops this session's recording and marks the meeting over. The transcript stays readable.",
                           changesData: true) { _, context in
                    try .structured(await MeetRecordingTools.stop(context))
                }
                PluginTool(id: "read_transcript",
                           description: "The latest lines of this session's recording transcript, oldest first: who spoke ('You' is the microphone, "
                               + "'Them' the other side), when, and what was said.",
                           input: .object(["limit": .integer("How many of the latest lines to return (default 100, at most 500)").optional])) { args, context in
                    try .structured(try await MeetRecordingTools.transcript(context, limit: try args.optionalInt("limit")))
                }
            }
        ]
    }
}

/// What the recordings tools do, over `MeetingRecorder.shared` and the session's own services.
@MainActor
enum MeetRecordingTools {

    static func status(_ context: PluginToolContext, recorder: MeetingRecorder = .shared) async -> MeetRecordingStatus {
        let dir = await fetchRecordingDir(services: context.services)
        let mine = dir.map { recorder.isRecording(dir: $0) } ?? false
        let active = recorder.active
        return MeetRecordingStatus(
            recording: active != nil, thisSession: mine,
            startedAt: active.map { ISO8601DateFormatter().string(from: $0.startedAt) },
            app: active?.app, recordingDir: dir)
    }

    static func start(_ context: PluginToolContext, recorder: MeetingRecorder = .shared) async throws -> MeetRecordingStatus {
        let services = context.services
        switch await recorder.start(services: recorder.services(for: services), app: "Agent", bundleId: "") {
        case .started(_, let dir):
            try? await services.storage.delete(key: "start_error")
            _ = await setMeetingValue("recording_dir", dir, tools: services.tools)
            _ = await setMeetingValue("started_at", isoNow(), tools: services.tools)
            try? await services.pill.present(widgetId: "recording", sessionId: context.sessionId)
            return await status(context, recorder: recorder)
        case .refused(let owner):
            throw PluginToolFailure(code: "already_recording", message: "a recording is already running (\(owner))",
                                    suggestion: "read recording_status; stop that recording first, or read its transcript")
        case .failed(let reason, let message):
            throw PluginToolFailure(code: reason, message: message.isEmpty ? "the recording could not start" : message,
                                    suggestion: reason.hasSuffix("_denied")
                                        ? "ask the person to turn the permission on in Work42's Settings → Permissions"
                                        : "check the audio devices, then try again")
        }
    }

    static func stop(_ context: PluginToolContext, recorder: MeetingRecorder = .shared) async throws -> MeetRecordingStatus {
        let services = context.services
        guard let dir = await fetchRecordingDir(services: services), recorder.isRecording(dir: dir) else {
            throw PluginToolFailure(code: "not_recording", message: "this session has no recording running",
                                    suggestion: "read recording_status to see whether any recording is running")
        }
        _ = await recorder.stop(dir: dir)
        _ = await setMeetingValue("ended_at", isoNow(), tools: services.tools)
        try? await services.pill.dismiss(widgetId: "recording")
        return await status(context, recorder: recorder)
    }

    static func transcript(_ context: PluginToolContext, limit: Int?, recorder: MeetingRecorder = .shared) async throws -> MeetTranscriptAnswer {
        guard let dir = await fetchRecordingDir(services: context.services) else {
            throw PluginToolFailure(code: "no_recording", message: "this session has no recording",
                                    suggestion: "start one with start_recording, or use a session that recorded a meeting")
        }
        let file = URL(fileURLWithPath: dir).appendingPathComponent("conversation.jsonl")
        let data = (try? Data(contentsOf: file)) ?? Data()
        let read = MeetTranscript.lines(in: data, limit: limit)
        return MeetTranscriptAnswer(lines: read.lines, total: read.total, recording: recorder.isRecording(dir: dir))
    }
}

