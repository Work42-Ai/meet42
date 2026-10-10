---
name: widget-summary
description: |
  How the Summary widget (session tab kindId widget:summary) works on a meet42
  meeting session. It shows the "meeting-summary" artifact the agent writes in the
  Summary stage, and contributes the "Summary ready · N action items" header label.
---

# Summary widget

Shows the session artifact `meeting-summary` full size, in the same style as the Meeting brief. The agent writes
it in the Summary stage by following the `meet42-summary` skill (`work42 artifact set meeting-summary …`), then
sets `meeting/summary` to `{"artifact":"meeting-summary","action_items":N}`. The widget reloads within about two
seconds whenever the artifact's `index.html` changes. Until it exists the widget says the agent writes the summary
when the meeting ends; if Work42's local artifact server isn't up it says so and offers **Retry**. Links inside the
summary open through Work42's Open Link.

The widget has no actions. To rewrite the summary, ask the agent in chat.

**Header label:** "Summary ready · N action items" (N from `meeting/summary`), or "Summary ready" when only the
artifact exists. It is shown on every tab and opens this widget (`meet42://widget/summary`).

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
