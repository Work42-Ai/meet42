---
name: widget-calendar
description: The meet42 Calendar widget — Day/Week/Agenda calendar-event views with per-calendar and per-event AI assist-mode pickers.
---

# Calendar widget

A calendar-only port of the app's Meetings view. Renders your real calendar
events in a Day / Week / Agenda layout (macOS Calendar.app-style hour grid with
collision-laid-out event blocks, an all-day strip, and a live current-time
line), and lets you set the AI assist mode per calendar and per event.

- **Data source:** shells the read-only meet42 CLI — `meet42 list --from <iso>
  --to <iso> --json` for the active window's events, and `meet42 modes get
  --json` for the per-calendar/-event assist modes. Toggling a mode writes via
  `meet42 modes set calendar|event <id> <view_only|assisted|ai_scheduled>`. It
  refreshes on a ~2s timer while mounted. The widget imports no calendar type —
  it decodes local `CalEvent` / `CalMode` mirrors.
- **Assist modes:** clicking an event opens a popover with its details; a
  view-only event offers "Enable AI assistance" (a per-event override). The gear
  button opens a settings popover with a per-calendar AI-assistance toggle.
  Colors: AI Assisted = violet, View only = blue, AI scheduled = orange.
- **Detection pill:** the Calendar background agent is the sole pre-session
  mic-open owner. One machine-wide `meet42 watch` stream presents the detected
  call app's native icon with Skip / Record now and a 10-second countdown.
  A nearby calendar event is attached only when its effective mode is
  `assisted`, it has a linked session id, and that session still resolves.
  View-only, AI-scheduled, unlinked, and stale-linked events are ignored
  completely; their title, event id, and schedule never leak into an ad-hoc
  call. The prompt title is the existing session's authoritative name, or the
  exact future ad-hoc session name chosen before the prompt appears.
  Starting launches an app-owned recorder, keeps the same 412x108 shared pill
  shell and meeting identity while its lower row reports setup progress, then
  seeds an existing prepared event session or runs
  `work42 session start --background` for a new one.
- **Handoff metadata:** Calendar writes `meeting/recording_dir`,
  `meeting/started_at`, `meeting/title` (the stable session name), `meeting/source_app`, and
  `meeting/source_bundle_id`. Matched events also receive
  `meeting/scheduled_start` and `meeting/scheduled_end`. Once ready, Calendar
  swaps its pill for that session's Recording pill without selecting the
  session in the main UI.
- **Failure behavior:** setup failures explicitly stop the just-started
  recording and leave a visible Retry action in the Calendar pill. Calendar
  only cancels a mic-close while the initial prompt is undecided; Recording
  owns active-meeting close behavior after handoff.
- **Idle pill:** outside detection/setup, `makePillView` renders a compact "Up
  Next" agenda (the next few upcoming events).
- **Out of scope (dropped from the app original):** AI-schedule authoring/UI,
  PlannedDay work-blocks, the sync-status/access header chip, and "Open in
  Calendar". Re-surfaced later via a separate collection.

## Background sync and the event popup

**Calendar sync.** meet42 keeps its own copy of your calendar, and nothing else refreshes it since meet42 left the
Work42 app. While Work42 runs, this widget's background agent (the one that holds the detector lock) runs
`meet42 sync` when it starts and every two minutes, but only after Calendar access has been granted to meet42, so it
never raises a permission prompt from the background. A new or edited event appears within about two minutes. Each run
is logged in `~/.work42/meet42/trace.jsonl` (`src: calendar`, `sync-ok` / `sync-failed`).

**Event popup.** Clicking an event opens a popup in the Event details style: the calendar's colour bar, source and
status chips, title, absolute time, the meeting link (with its provider and a copy button), location, guests with their
replies, and the description (the notes as sanitised HTML; Google's `-::~:~::~` divider lines are dropped and long lines
wrap, so nothing scrolls sideways). The popup is 440 points wide and up to 680 tall; the body scrolls vertically and the button row stays at the bottom:
- **Join meeting**, opened by macOS (the Zoom or Teams app when installed, otherwise your browser).
- One AI control: **Open session in Work42** when the event has a session; **Create session now** (with a caption
  "A session is created automatically at h:mm", 15 minutes before the start) when the event is AI-assisted and has no
  session yet; **Enable AI assistance** on a
  view-only calendar.

**Create session now** creates the event session the same way the automatic one is created, cancels the scheduled
`mtg:<id>` entry and reloads the popup, so the event never gets a second session. The scheduler also skips events that
already have a session.

## Prerequisites

meet42 is a separate command-line tool (github.com/Work42-Ai/meet42), not part of the Work42 app. Before relying
on this, check `command -v meet42`: it must print a path. If it prints nothing, or a meet42 command fails
because the tool is missing, ask the user whether to install it (never install it without their yes); if they
agree, follow the `meet42-setup` skill, which installs the signed release, grants its permissions and loads the
calendar.
