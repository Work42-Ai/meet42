// meet42 — the open-source macOS calendar + meetings CLI.
//
// Manual arg dispatch (no ArgumentParser). Read verbs go through the ported
// Meet42Kit `CalendarStore`; `sync` puts the events Work42 read into it. meet42
// holds no privacy permission: Work42 reads the calendars and records the audio
// (2.0.0), so there is no `record` and no `permissions` verb. stdout carries
// verb output (JSON with `--json`, else human text); all diagnostics go to stderr.

import Foundation

let meet42Version = "2.0.0"

let argv = CommandLine.arguments
let command = argv.count > 1 ? argv[1] : "help"
let rest = Array(argv.dropFirst(2))

await Dispatcher.run(command: command, args: rest)

@MainActor
enum Dispatcher {

    static func run(command: String, args: [String]) async {
        switch command {
        case "list":     ReadCommands.list(args: args)
        case "today":    ReadCommands.today(args: args)
        case "next":     ReadCommands.next(args: args)
        case "show":     ReadCommands.show(args: args)
        case "now":      ReadCommands.now(args: args)
        case "snapshot":      DataCommands.snapshot(args: args)
        case "link-session":  DataCommands.linkSession(args: args)
        case "people":        DataCommands.people(args: args)
        case "mics":     MicsCommand.mics(args: args)
        case "watch":    WatchCommand.watch(args: args)   // never returns
        case "modes":    DataCommands.modes(args: args)
        case "sync":     SyncCommand.sync(args: args)
        case "transcript": TranscriptCommand.transcript(args: args)
        case "notes":    NotesCommand.notes(args: args)
        case "trace":    TraceCommand.trace(args: args)
        case "version", "--version", "-v":
            print("meet42 v\(meet42Version)")
        case "help", "--help", "-h", "":
            printUsage()
        default:
            CLI.warn("meet42: unknown command: \(command)")
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        meet42 v\(meet42Version) — calendar + meetings CLI

        Usage: meet42 <command> [options]

        Every read verb accepts --json; each event payload carries the event `id`.

        Calendar reads:
          list [--from <iso>] [--to <iso>] [--source <id>] [--json]
                List events in a window. Defaults to today.
          today [--json]
                Events between local midnight and +24h.
          next [--json]
                The next upcoming (non-canceled) event, or null.
          show <eventId|next> [--json]
                Full details for one event.
          now [--json]
                The current meeting ([startsAt−5m, endsAt] contains now)
                or the next one starting within ~5 min; null if neither.

        Sessions / people:
          snapshot <eventId> --session-dir <dir> [--json]
                Write meeting.json for the event + seed the people graph.
          link-session <eventId> <sessionId> [--json]
                Link a Work42 session back to its calendar event so
                `meet42 now` surfaces the existing sessionId for dedup.
                Idempotent — safe to call multiple times for the same eventId.
          people (--session-dir <dir> | --meeting-json <path>) [--json]
                Attendee profiles (shared-meeting counts) from the snapshot.

        Audio / modes:
          mics [--json]
                List microphone input devices for the mic picker.
          mics select <uid>
                Persist a microphone selection (writes
                ~/.work42/meet42/mic-input-device.json).
          watch [--bundle-id <id>] [--json]
                Long-lived; emits {"event":"call-open"} / {"event":"call-close"}
                line-delimited JSON on call-app input transitions. --bundle-id
                restricts observation to one detected meeting app.
          modes get [--json]
                Per-calendar / per-event assistance flags, plus calendarTypes
                and eventTypes (the session type each starts; none = event).
          modes set <calendar|event> <id> <view_only|assisted|ai_scheduled>
                Set an assistance flag.
          modes set-type <calendar|event> <id> <typeId|default> [--json]
                Set the session type a calendar's events start, or one event's
                override of it. "default" clears it (event, or its calendar's).

        Calendar sync:
          sync --events <file> [--from <iso>] [--to <iso>] [--json]
                Replace the calendar copy for the window with the events in
                <file> (a JSON array). Work42 reads your calendars with its own
                Calendar permission and runs this itself; meet42 holds no
                privacy permission and neither records nor reads calendars.

        Recordings:
          transcript --dir <dir> [--json]
                Read-only. A recording's conversation.jsonl and speakers.json.
                --json prints {"dir","conversation","speakers"}: the files
                verbatim, `speakers` absent until the end-of-meeting
                attribution writes it. Lets a device that is not this Mac
                (the iPad app) show the live transcript.
          notes write --base64 <payload> [--dir <folder>] [--json]
                Replace the session's My Notes file (annotations.md) with the
                base64-decoded text; an empty payload clears it. --dir defaults
                to the current directory (the session folder when Work42 runs
                it). Lets a device that is not this Mac (the iPad app) save
                notes. Only annotations.md is ever written.

        Diagnostics:
          trace [--tail N] [--call <callId>] [--json]
                Pretty-print the last N pipeline events from
                ~/.work42/meet42/trace.jsonl (default --tail 50).
                --call <id> filters to one call session.
                --json emits raw JSON lines. Reads always work regardless
                of the MEET42_TRACE=0 env var (which only gates writes).

          version | --version
          help | --help

        Data lives under:
          ~/.work42/meet42/calendar.db    (calendar mirror)
          ~/.work42/meet42/modes.json     (assistance flags)
          ~/.work42/meet42/trace.jsonl    (pipeline trace log)
          ~/.work42/peers42/people.db     (people graph)
        """)
    }
}
