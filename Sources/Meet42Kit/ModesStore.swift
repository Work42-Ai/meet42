// ModesStore.swift — per-calendar / per-event assistance flags for meet42.
// (meet42-plugin-conversion, M1/s9).
//
// A tiny JSON-backed store at `~/.work42/meet42/modes.json`. The shape is:
//
//   {
//     "calendars": { "<calendarId>": "view_only" | "assisted" | "ai_scheduled" },
//     "events":    { "<eventId>":    "view_only" | "assisted" | "ai_scheduled" }
//   }
//
// The values reuse `CalendarStore.CalendarMode` so the `view_only` /
// `assisted` / `ai_scheduled` vocabulary is identical across the calendar
// renderer and the `meet42 modes` verb. An event override wins over its
// calendar's preference, which in turn wins over the global default
// (`.viewOnly`) — see `effectiveMode(forEvent:calendarId:)`.
//
// Persistence is a best-effort atomic temp-file + `rename(2)` swap so a
// concurrent reader never sees a partial write. A missing file loads as an
// empty store (every lookup falls through to `.viewOnly`).

import Foundation

public final class ModesStore {

    /// The on-disk JSON shape. `CalendarStore.CalendarMode` is `Codable`
    /// over its `String` rawValue, so this encodes directly to the documented
    /// `{calId: "view_only"}` form.
    public struct File: Codable, Sendable, Equatable {
        public var calendars: [String: CalendarStore.CalendarMode]
        public var events: [String: CalendarStore.CalendarMode]
        /// The session type a calendar's events start (a `session_types` id). A calendar with no entry uses `event`.
        public var calendarTypes: [String: String]
        /// The session type one event starts, overriding its calendar's. An event with no entry follows its calendar.
        public var eventTypes: [String: String]

        public init(
            calendars: [String: CalendarStore.CalendarMode] = [:],
            events: [String: CalendarStore.CalendarMode] = [:],
            calendarTypes: [String: String] = [:],
            eventTypes: [String: String] = [:]
        ) {
            self.calendars = calendars
            self.events = events
            self.calendarTypes = calendarTypes
            self.eventTypes = eventTypes
        }

        // A file written before session types existed has neither type map: decode them as empty.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            calendars = try container.decodeIfPresent([String: CalendarStore.CalendarMode].self, forKey: .calendars) ?? [:]
            events = try container.decodeIfPresent([String: CalendarStore.CalendarMode].self, forKey: .events) ?? [:]
            calendarTypes = try container.decodeIfPresent([String: String].self, forKey: .calendarTypes) ?? [:]
            eventTypes = try container.decodeIfPresent([String: String].self, forKey: .eventTypes) ?? [:]
        }
    }

    /// The session type an event starts when nothing says otherwise.
    public static let defaultTypeId = "event"

    public let path: String
    private var file: File

    /// `~/.work42/meet42/modes.json` by default.
    public static func defaultPath() -> String {
        (Meet42Paths.meet42Root() as NSString)
            .appendingPathComponent("modes.json")
    }

    /// Open the store, loading the backing file if present. A missing or
    /// unreadable file loads as an empty store (never throws on load).
    public init(path: String = ModesStore.defaultPath()) {
        self.path = path
        self.file = Self.load(path: path)
    }

    private static func load(path: String) -> File {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            !data.isEmpty,
            let decoded = try? JSONDecoder().decode(File.self, from: data)
        else {
            return File()
        }
        return decoded
    }

    // MARK: - Reads

    /// The whole file (both maps). Convenience for `meet42 modes get`.
    public func all() -> File { file }

    /// The explicit mode set for `calendarId`, or nil if none.
    public func calendarMode(for calendarId: String) -> CalendarStore.CalendarMode? {
        file.calendars[calendarId]
    }

    /// The explicit mode set for `eventId`, or nil if none.
    public func eventMode(for eventId: String) -> CalendarStore.CalendarMode? {
        file.events[eventId]
    }

    /// Resolve the mode that applies to an event: an event override wins,
    /// then the event's calendar preference, then the global `.viewOnly`
    /// default.
    public func effectiveMode(
        forEvent eventId: String,
        calendarId: String
    ) -> CalendarStore.CalendarMode {
        file.events[eventId] ?? file.calendars[calendarId] ?? .viewOnly
    }

    /// The session type an event starts: its own override, else its calendar's default, else `event`.
    public func effectiveType(forEvent eventId: String, calendarId: String) -> String {
        file.eventTypes[eventId] ?? file.calendarTypes[calendarId] ?? Self.defaultTypeId
    }

    // MARK: - Writes

    /// Set (or, with nil, back to the default) the session type of a calendar's events. Persists atomically.
    public func setType(calendar calendarId: String, typeId: String?) throws {
        if let typeId {
            file.calendarTypes[calendarId] = typeId
        } else {
            file.calendarTypes.removeValue(forKey: calendarId)
        }
        try persist()
    }

    /// Set (or, with nil, back to its calendar's) the session type of one event. Persists atomically.
    public func setType(event eventId: String, typeId: String?) throws {
        if let typeId {
            file.eventTypes[eventId] = typeId
        } else {
            file.eventTypes.removeValue(forKey: eventId)
        }
        try persist()
    }

    /// Set (or, with nil, clear) the per-calendar mode. Persists atomically.
    public func setCalendarMode(
        _ mode: CalendarStore.CalendarMode?,
        for calendarId: String
    ) throws {
        if let mode {
            file.calendars[calendarId] = mode
        } else {
            file.calendars.removeValue(forKey: calendarId)
        }
        try persist()
    }

    /// Set (or, with nil, clear) the per-event mode. Persists atomically.
    public func setEventMode(
        _ mode: CalendarStore.CalendarMode?,
        for eventId: String
    ) throws {
        if let mode {
            file.events[eventId] = mode
        } else {
            file.events.removeValue(forKey: eventId)
        }
        try persist()
    }

    // MARK: - Persistence

    private func persist() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        let data = try encoder.encode(file)
        let tmpPath = path + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        if rename(tmpPath, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
