---
name: widget-summary
description: |
  How the Summary widget (session tab kindId widget:summary) works on a meet42
  meeting session. It is empty until the end-of-meeting pass writes summary.md,
  then renders that file as themed markdown.
---

# Summary widget

Renders a meeting session's `summary.md` as themed markdown (via
`Work42MarkdownDocument` — inline `[[artifact:id]]` embeds + the shared comment
layer). The tile shows a waiting/empty state until the end-of-meeting agent
pass writes the file, then renders the structured summary — decisions, action
items, open questions, best-effort speaker attribution.

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
