// EventSessionType.swift — the `calendar` MCP of an Event session (WOR-901).
//
// What an Event session's agent can read of its calendar: the event the session is for, and the days around it. It reads through
// `services.calendar` (Work42 holds the Calendar permission), where it used to run the `meet42` command line. The answers are
// shaped in MeetTools.swift.

import Foundation
import Work42PluginKit

@MainActor
final class EventSessionType: Work42SessionTypeMCPs {

    var mcpTools: [PluginMCPTools] {
        [
            PluginMCPTools(id: "calendar") {
                PluginTool(id: "get_event",
                           description: "The calendar event this session is for: title, time, place, organizer, attendees and their answers, notes and meeting link.") { _, context in
                    try .structured(try await Self.event(of: context.services))
                }
                PluginTool(id: "list_events",
                           description: "Events on the person's calendars between two times, soonest first (at most 200, at most 90 days).",
                           input: .object([
                               "from": .dateTime("Start of the window (ISO 8601). Default: now.").optional,
                               "to": .dateTime("End of the window (ISO 8601). Default: a week after 'from'.").optional,
                           ])) { args, context in
                    let from: Date? = try args.optionalString("from") == nil ? nil : args.date("from")
                    let to: Date? = try args.optionalString("to") == nil ? nil : args.date("to")
                    let window = try MeetEventListing.window(from: from, to: to, now: Date())
                    let events = try await context.services.calendar.events(from: window.from, to: window.to)
                    return try .structured(MeetEventList(events: MeetEventListing.summaries(events)))
                }
            }
        ]
    }

    /// The linked event of a session, from its `meeting/event_id`, read through the calendar service.
    static func event(of services: SessionServices, now: Date = Date()) async throws -> MeetEventSummary {
        guard case .string(let id)? = try? await services.storage.get(namespace: "meeting", key: "event_id"), !id.isEmpty else {
            throw PluginToolFailure(code: "no_event", message: "this session has no calendar event",
                                    suggestion: "it is an ad-hoc event session; list_events shows what is on the calendar")
        }
        guard let found = try await MeetEventLoader.find(eventID: id, calendar: services.calendar, now: now) else {
            throw PluginToolFailure(code: "event_not_found", message: "that event is no longer in the calendars",
                                    suggestion: "it may have been deleted or moved far from today; list_events shows what is there")
        }
        return MeetEventSummary(found)
    }
}
