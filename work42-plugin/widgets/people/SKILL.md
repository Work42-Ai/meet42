---
name: widget-people
description: The meet42 People widget — attendee profiles for the current event.
---

# People widget

Read-only. Shows the event's attendees with their accumulated profile from
meet42's people store: display name, email, shared-meeting count, and last-seen
(relative). Organizer / you chips come from the event's attendee list.

- **Data source:** shells `meet42 people --session-dir <dir> --json` (the
  standalone meet42 CLI reads its own `people.db`); attendee organizer/you flags
  come from `<dir>/meeting.json`. The widget imports no calendar/people type.
- **Empty state:** "No attendee data" when there is no `meeting.json` or it
  lists no attendees; "No accumulated data yet" when attendees exist but have no
  recorded shared meetings yet.
- **Pill:** `makePillView` renders a compact attendee list so People can float.

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
