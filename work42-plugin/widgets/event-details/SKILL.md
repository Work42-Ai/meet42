---
name: widget-event-details
description: |
  How the Event details widget (session tab kindId widget:event-details) works on a meet42
  meeting session: the calendar event read live through meet42, the header time label, and
  the Join action.
---

# Event details widget

Shows the session's calendar event. The session stores only the event id (`meeting/event_id`); the widget runs
`meet42 show <event_id> --json` on appear and every 60 seconds, so it reflects edits made in the calendar. The same
command is the agent's source for the event: there is no `meeting.json`.

**Card:** the calendar's colour bar, a source chip ("Google · Work") and a status chip, the title, the absolute date
and time (all-day aware), the meeting link with its provider (Google Meet, Zoom, Microsoft Teams, Webex, otherwise the
host) and a copy button, the location (hidden when it is the meeting link), a guests summary with an RSVP bar, and the
description (the event notes as sanitised HTML, rendered by the SDK markdown viewer, collapsed behind **Show more**).

**Not linked:** an event session created without a calendar event shows "Not linked to a calendar event". If `meet42`
is missing or `show` fails, the widget shows the error and the command that failed.

**Header label (every tab):** "Starts in N min" from 60 minutes before the start, "Live · N min left" during the
meeting, "Ended h:mm" afterwards. It opens this widget (`meet42://widget/event-details`).

**Action:** **Join**, in the provider's brand colour, from 15 minutes before the start until the end, for an event
with a meeting link. It opens the link with the operating system (the Zoom or Teams app when installed, otherwise the
default browser), never inside Work42. It shows on the tab where this widget is.

## Prerequisites

meet42 is a separate command-line tool (github.com/Work42-Ai/meet42), not part of the Work42 app. Before relying
on this, check `command -v meet42`: it must print a path. If it prints nothing, or a meet42 command fails
because the tool is missing, ask the user whether to install it (never install it without their yes); if they
agree, follow the `meet42-setup` skill, which installs the signed release, grants its permissions and loads the
calendar.

## Session file

| File | Access | Description |
|------|--------|-------------|
| `<dir>/meeting.json` | read-only | The event snapshot (`{ event, snapshotAt }`), written by meet42. The widget decodes it through a local mirror of `CalendarEvent.Item` and reloads via a 1s file watcher when meet42 rewrites it. |

The widget never writes. It reads the session worktree dir from
`services.worktreePath`.

## Pill

`makePillView` renders a compact card: event title + time range + attendee
count.
