# meet42 plugin

Built in to Work42: the app installs this plugin and the signed meet42 CLI at launch and updates them with the app. Ask the agent to set meet42 up (the `meet42-setup` skill checks the CLI and walks through permissions).

The meeting vertical, extracted from work42 into a first-party plugin
(meet42-plugin-conversion, M2). The plugin is **UI + orchestration only** — all
privileged calendar/audio work lives in the standalone [`meet42` CLI](../)
(the same repository; its own signed release, own TCC identity). The only contract between them
is that CLI: verbs in, JSON/exit-codes out, and files written into a session's
`--session-dir`.

## Contributions

| Kind | What |
|------|------|
| **Workflow** (`workflows/meeting.json`) | `Prepare for Meeting -> In Meeting -> Summary -> Done`, driven entirely by recording-lifecycle storage signals (`meeting/started_at`, `meeting/ended_at`, `meeting/summary`) — no wall-clock timer. Read-only capability rules (local diagnostics + this workflow's own storage-read / transition / artifact verbs + `meet42`); artifact-write allowed while active, blocked at Done. |
| **Session type** (`session-types/event.json`) | `event` type on the `meeting` workflow; 3-tab layout (Brief / Live / Recap) over the plugin's custom widgets and two artifact tiles (`artifact:meeting-brief` on Brief, `artifact:meeting-summary` on Recap, shown empty until the agent writes them); `list_shape: schedule`, `archive_source: meeting`, `self_archives`; the `meet42-prep` session skill; a `new-event` create-intent; an `event_id` string arg seeded to `meeting/event_id`. |
| **Intent** (`intents/new-event.json`) | "New Event" — mints an `event` session (optionally carrying `event_id`). |
| **onCreate hook** (`extension/Sources/Hooks.swift`) | When `event_id` is present, shells `meet42 link-session <id> <session> --session-dir <dir>` so the event and its session find each other; no-op for an ad-hoc event. |
| **Widgets** (`widgets/*`, s12-s16) | event-details / recording / annotations / calendar / permissions — render over session files + `meet42` verbs. (The Brief and Recap are not widgets of the plugin: they are the session's `meeting-brief` and `meeting-summary` artifacts, drawn by Work42 as artifact tiles.) The recording widget carries the RECORDING/ENDED pill + auto-record agent; the calendar widget carries the mic-wake detection agent + scheduler reconciler; the permissions widget shows the four macOS permissions meet42 needs, one row each, with Grant / Open Settings per row (Work42 holds the permissions) (and a note to ask the agent to set meet42 up when the tool is missing). |
| **Skill** (`skills/meet42-prep`, s13) | Type-scoped briefing skill run in the Prepare-for-Meeting stage. |

## Building

The plugin runs in its own extension process (`runtime: extension`, `sdk_version: 3.3.0`): `work42 plugin build` compiles
`extension/Sources/*.swift` (the five widgets, the `MeetingRecorder`, the onCreate hook and the extension's `@main`) into a
sandboxed ExtensionKit extension, and `work42 plugin package` signs and zips it. The extension holds no privacy permission:
recording, transcribing and reading the calendars go through Work42's `services.audio`, `services.speech` and
`services.calendar` (declared under `permissions` in `plugin.yaml`), and `file_access` gives it `~/.work42/meet42`.
The same sources are built by SwiftPM as the `Meet42Widgets` library the Work42 iPad app links.
