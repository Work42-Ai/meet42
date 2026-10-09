---
name: widget-event-details
description: |
  How the Event Details widget (session tab kindId widget:event-details) works
  on a meet42 meeting session. It renders the calendar event the session was
  minted around — title, time, RSVP/status, location, organizer, attendees,
  notes — from the session's meeting.json snapshot.
---

# Event Details widget

Renders a meeting session's event detail from the `meeting.json` snapshot that
meet42 writes (and rewrites on each calendar sync) next to the session. Shows
title, time range, the user's RSVP + the meeting's status, location, organizer,
the attendee list (with per-attendee RSVP dots, organizer/you chips), notes,
and a "synced Ns ago" footer. A "Join meeting" link appears when the snapshot
carries a meeting URL. Empty until the snapshot exists.

## Prerequisites

meet42 is a separate command-line tool (github.com/Work42-Ai/meet42), not part of the Work42 app. Before relying
on this, check it:

1. `command -v meet42` must print a path. If it prints nothing, install the latest signed release:

   ```bash
   mkdir -p ~/.work42/bin && cd "$(mktemp -d)"
   curl -fsSLO https://github.com/Work42-Ai/meet42/releases/latest/download/meet42.zip
   curl -fsSLO https://github.com/Work42-Ai/meet42/releases/latest/download/meet42.zip.sha256
   shasum -a 256 -c meet42.zip.sha256
   ditto -x -k meet42.zip ~/.work42/bin/
   ```

   `shasum` must print `meet42.zip: OK`. If it does not, stop and tell the user; do not run the download.
2. `meet42 permissions --json` lists `calendar`, `microphone`, `speech` and `screen`. For each `not_determined`,
   run `meet42 permissions request <name>` (macOS shows a prompt that names meet42; ask the user to allow it).
   For one that is `denied`, and for `screen` (macOS has no prompt for it), ask the user to switch meet42 on in
   System Settings: `meet42 permissions open <name>`. The **meet42 permissions** widget on an event's Brief tab
   does the same one row at a time.
3. `meet42 sync` once, so the calendar is loaded.

## Session file

| File | Access | Description |
|------|--------|-------------|
| `<dir>/meeting.json` | read-only | The event snapshot (`{ event, snapshotAt }`), written by meet42. The widget decodes it through a local mirror of `CalendarEvent.Item` and reloads via a 1s file watcher when meet42 rewrites it. |

The widget never writes. It reads the session worktree dir from
`services.worktreePath`.

## Pill

`makePillView` renders a compact card: event title + time range + attendee
count.
