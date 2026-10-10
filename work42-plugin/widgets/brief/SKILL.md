---
name: widget-brief
description: |
  How the Meeting brief widget (session tab kindId widget:brief) works on a meet42
  meeting session. It shows the "meeting-brief" artifact the agent writes while
  preparing for the meeting, and contributes the "Preparing brief… / Brief ready" label.
---

# Meeting brief widget

Shows the session artifact `meeting-brief` full size. The agent writes it in the Prepare for Meeting stage by
following the `meet42-brief` skill (`work42 artifact set meeting-brief …`): why the meeting is happening, the
people, a card per connected source with direct links, open items, and a suggested agenda. The widget reloads within
about two seconds whenever the artifact's `index.html` changes. Until it exists the widget says the agent prepares
the brief before the meeting; if Work42's local artifact server isn't up it says so and offers **Retry**. Links inside
the brief open through Work42's Open Link.

The widget has no actions. To rebuild the brief, ask the agent in chat.

**Header label:** "Preparing brief…" while the stage is Prepare for Meeting and the artifact doesn't exist yet,
"Brief ready" once it does; shown on every tab, opens this widget (`meet42://widget/brief`).

## Prerequisites

meet42 is a separate command-line tool (github.com/Work42-Ai/meet42), not part of the Work42 app. Before relying
on this, check `command -v meet42`: it must print a path. If it prints nothing, or a meet42 command fails
because the tool is missing, ask the user whether to install it (never install it without their yes); if they
agree, follow the `meet42-setup` skill, which installs the signed release, grants its permissions and loads the
calendar.

## Session file

| File | Access | Description |
|------|--------|-------------|
| `<dir>/summary.md` | read-only | The meeting summary markdown. Written by the end-of-meeting agent pass; rendered here and re-read via a 1s file watcher when it changes. |

The widget reads the session worktree dir from `services.worktreePath` and
registers the session with the artifact runtime on `activate` so inline embeds
resolve.

## Agent usage

```bash
# Write the structured summary at the end of a meeting
cat > "$WORK42_SESSION_DIR/summary.md" <<'MD'
## Decisions
...
## Action items
...
MD
```

## Pill

`makePillView` renders the same scrollable markdown (or the empty state)
without the header.
