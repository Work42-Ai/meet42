---
name: widget-permissions
description: |
  How the meet42 Permissions widget (session tab kindId widget:permissions) works. It lists the four macOS
  privacy permissions meet42 needs (Calendar, Microphone, Speech recognition, Screen & system audio), one row
  each, and gives each row its own action. It lives only on meet42 `event` sessions, on the Brief tab. Use it,
  or the same `meet42 permissions` verbs, when a recording or calendar sync fails with a permission error.
---

# meet42 Permissions widget

A small tile showing, always as four separate rows, whether macOS lets **meet42** use the Calendar, Microphone,
Speech recognition and Screen & system audio recording. Granted rows stay visible.

| Row status | Pill | Button | Runs |
|------------|------|--------|------|
| `not_determined` (never asked) | Not asked | **Request** | `meet42 permissions request <name>` shows macOS's prompt |
| `denied` | Denied (Off for screen) | **Open Settings** | `meet42 permissions open <name>` |
| `restricted` | Restricted | **Open Settings** | same; a profile or parental control may block it |
| `granted` | Granted | **Open Settings** | same, to review or revoke |

macOS asks only once per permission, so a denied one is switched on in System Settings, not re-requested.
**Screen & system audio** never has a prompt: the user switches meet42 on under *Privacy & Security → Screen &
System Audio Recording*, and meet42 must be started again afterwards.

The tile re-checks when it opens, when the Refresh button is pressed, and whenever Work42 becomes the active app
again, so a switch flipped in System Settings shows up on its own.

When the `meet42` tool is not installed the tile says so and offers **Set up meet42**, which runs
`work42 plugin setup meet42`: a chat session that follows this plugin's skills to install it.

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
