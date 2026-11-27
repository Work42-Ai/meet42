// SyncCommand.swift — `meet42 sync --events <file>`: put the calendar events Work42 read into calendar.db.
//
// meet42 no longer reads the calendars itself (and no longer holds the Calendar permission): Work42 does, through its
// `services.calendar`, and the meet42 extension runs this with the events it got. The mapping lives in Meet42Kit's
// `CalendarIngest`, so it is tested without a command line.

import Foundation
import Meet42Kit

@MainActor
enum SyncCommand {

    private struct SyncResult: Encodable {
        let synced: Bool
        let count: Int
        let message: String
    }

    /// The window the file covers when `--from`/`--to` are not given: what the EventKit sync read.
    private static let defaultPastWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let defaultFutureWindow: TimeInterval = 90 * 24 * 60 * 60

    static func sync(args: [String]) {
        guard let path = CLI.argValue(args, "--events") else {
            CLI.fail(
                "meet42 sync: expected --events <file> (a JSON array of calendar events). meet42 no longer reads your calendars "
                    + "itself: Work42 reads them with its own Calendar permission and runs this for you.", code: 2)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            CLI.fail("meet42 sync: couldn't read \(path): \(error.localizedDescription)", code: 2)
        }

        let now = Date()
        let from = CLI.argValue(args, "--from").flatMap(CLI.parseDate) ?? now.addingTimeInterval(-defaultPastWindow)
        let to = CLI.argValue(args, "--to").flatMap(CLI.parseDate) ?? now.addingTimeInterval(defaultFutureWindow)
        guard from < to else { CLI.fail("meet42 sync: --from must be before --to", code: 2) }

        let items: [CalendarEvent.Item]
        do {
            items = try CalendarIngest.items(from: data, syncedAt: now)
        } catch {
            CLI.fail("meet42 sync: \(error.localizedDescription)", code: 2)
        }

        do {
            let store = try CalendarStore()
            try store.replaceWindow(from: from, to: to, items: items)
            // Calendar access is Work42's now; these keys stay so `meet42` readers that look for them find a granted state.
            try store.setSyncState("access_state", value: "fullAccess")
            try store.setSyncState("access_granted", value: "1")
            try store.setSyncState("last_full_sync", value: CLI.nowISO())
            try store.setSyncState("last_full_sync_count", value: String(items.count))
        } catch {
            CLI.fail("meet42 sync: couldn't write calendar.db: \(error)", code: 2)
        }

        let result = SyncResult(synced: true, count: items.count, message: "Synced \(items.count) event(s).")
        if CLI.wantsJSON(args) {
            CLI.emitJSON(result)
        } else {
            print(result.message)
        }
    }
}
