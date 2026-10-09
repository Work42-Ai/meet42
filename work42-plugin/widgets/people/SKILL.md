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
on this, check `command -v meet42`: it must print a path. If it prints nothing, or a meet42 command fails
because the tool is missing, follow the `meet42-setup` skill, which installs the signed release, grants its
permissions and loads the calendar.
