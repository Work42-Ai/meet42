---
name: widget-annotations
description: |
  How the My Notes widget (session tab kindId widget:annotations) works on a
  meet42 meeting session. It is an editable notes tile whose contents persist
  to annotations.md in the session dir, readable by the agent.
---

# My Notes (annotations) widget

An editable personal-notes tile. Type into it during a meeting and the content
is saved — debounced (~500 ms), atomic (temp file + rename) — to
`annotations.md` inside the session dir, so it is part of the session and the
agent can read it. Reloads on external change (the agent or meet42 writing a
note) only when the editor is unfocused and has no unsaved local edits, so it
never clobbers in-flight typing. Shows a placeholder when empty.

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
| `<dir>/annotations.md` | read + write | The user's notes. Written by this widget on edit; readable by the agent and re-read via a 1s file watcher when changed out-of-band. |

The widget reads the session worktree dir from `services.worktreePath`.

## Agent usage

```bash
# Read the user's notes for a meeting session
cat "$WORK42_SESSION_DIR/annotations.md"
```

## Pill

`makePillView` renders a compact editor (the text area without the header),
backed by the same load + atomic-save path.
