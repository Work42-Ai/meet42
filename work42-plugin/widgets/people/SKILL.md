---
name: widget-people
description: |
  How the People widget (session tab kindId widget:people) works on a meet42 meeting
  session: the guests of the calendar event grouped by reply, and the header avatar label.
---

# People widget

Shows the guests of the session's calendar event, read live from `meet42 show <event_id> --json` (the id is the
session's `meeting/event_id`; there is no `meeting.json` and no `meet42 people` call), on appear and every 60 seconds.

**Summary:** an avatar stack (up to 4), "N people" and "a going · b maybe · c no reply". **Groups:** Going (accepted),
Maybe (tentative), No reply (pending and unknown) and Declined; empty groups are hidden. **Rows:** an initials avatar
whose colour comes from the email (else the name; the transcript and the header label use the same avatar), the
name (else the email), Organizer and You chips, the email under the name when both exist, and the reply icon.

**Not linked / no guests:** an event session created without a calendar event shows "No guest list". If `meet42` is
missing or `show` fails, the widget shows the error and the command that failed.

**Header label (every tab):** one grouped pill with up to 3 avatar segments and "N people · a going", amber while
anyone is tentative, pending or unknown. It opens this widget (`meet42://widget/people`).

## Prerequisites

meet42 is a separate command-line tool (github.com/Work42-Ai/meet42), not part of the Work42 app. Before relying
on this, check `command -v meet42`: it must print a path. If it prints nothing, or a meet42 command fails
because the tool is missing, ask the user whether to install it (never install it without their yes); if they
agree, follow the `meet42-setup` skill, which installs the signed release, grants its permissions and loads the
calendar.
