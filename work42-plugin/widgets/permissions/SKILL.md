---
name: widget-permissions
description: |
  How the meet42 Permissions widget (session tab kindId widget:permissions) works. It lists the four macOS
  privacy permissions meet42 needs (Calendar, Microphone, Speech recognition, System audio), one row
  each, and gives each row its own action. It lives only on meet42 `event` sessions, on the Brief tab. Use it,
  or the same `meet42 permissions` verbs, when a recording or calendar sync fails with a permission error.
---

# meet42 Permissions widget

A small tile showing, always as four separate rows, whether macOS lets **meet42** use the Calendar, Microphone,
Speech recognition and System audio. Granted rows stay visible.

| Row status | Pill | Button | Runs |
|------------|------|--------|------|
| `not_determined` (never asked) | Not asked | **Request** | `meet42 permissions request <name>` shows macOS's prompt |
| `denied` | Denied | **Open Settings** | `meet42 permissions open <name>` |
| `restricted` | Restricted | **Open Settings** | same; a profile or parental control may block it |
| `granted` | Granted | **Open Settings** | same, to review or revoke |

macOS asks only once per permission, so a denied one is switched on in System Settings, not re-requested.
**System audio** is macOS's "System Audio Recording Only" permission, with its own prompt naming meet42. meet42
never records the screen.

The tile re-checks when it opens, when the Refresh button is pressed, and whenever Work42 becomes the active app
again, so a switch flipped in System Settings shows up on its own.

When the `meet42` tool is not installed the tile says so. Ask the agent in any session to set meet42 up: it
follows the `meet42-setup` skill, which installs the tool and then checks these permissions.

The "meet42 needs setup" header label (from the Recording widget) links to this widget (`meet42://widget/permissions`),
so clicking it reveals the permissions.

## Prerequisites

meet42 is a separate command-line tool (github.com/Work42-Ai/meet42), not part of the Work42 app. Before relying
on this, check `command -v meet42`: it must print a path. If it prints nothing, or a meet42 command fails
because the tool is missing, ask the user whether to install it (never install it without their yes); if they
agree, follow the `meet42-setup` skill, which installs the signed release, grants its permissions and loads the
calendar.
