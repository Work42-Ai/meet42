---
name: widget-permissions
description: |
  How the meet42 Permissions widget (session tab kindId widget:permissions) works. It lists the four macOS
  privacy permissions meet42 uses (Calendar, Microphone, Speech recognition, System audio), one row
  each, and gives each row its own action. It lives only on meet42 `event` sessions, on the Brief tab. Use it
  when a recording or calendar sync fails with a permission error.
---

# meet42 Permissions widget

A small tile showing, always as four separate rows, whether Work42 may use the Calendar, Microphone,
Speech recognition and System audio **for meet42**. Granted rows stay visible.

Work42 holds these permissions, not meet42 and not the plugin's extension (macOS does not give them to an extension): Work42
records the audio, transcribes it and reads the calendars for the plugin. So macOS's prompts and System Settings name
**Work42**, and the widget goes through Work42's permission service (`services.permissions`).

| Row status | Pill | Button | Does |
|------------|------|--------|------|
| `notAsked` (nobody has been asked) | Not asked | **Grant** | Work42's pill, then macOS's own prompt |
| `denied` | Denied | **Open Settings** | opens that permission's System Settings page; switch **Work42** on there |
| `notDeclared` | Not declared | **Open Settings** | the plugin's manifest does not list it (should not happen) |
| `granted` | Granted | **Open Settings** | the same page, to review or revoke |

macOS asks only once per permission, so a denied one is switched on in System Settings, not asked again.
**System audio** is macOS's "System Audio Recording Only" permission. Nothing records the screen.

The tile re-checks every few seconds while it is on screen (the extension is never told when Work42 comes back to the
front), and when **Check again** is pressed, so a switch flipped in System Settings shows up on its own.

Under the rows the tile says which `meet42` command line is installed, or that it is not. The command line is still what
agents read the calendar and the recordings with (`meet42 list`, `meet42 transcript`, …). If it is missing, ask the agent in any
session to set meet42 up: it follows the `meet42-setup` skill.

The "meet42 needs setup" header label (from the Recording widget) links to this widget (`meet42://widget/permissions`),
so clicking it reveals the permissions. It shows while any permission is not granted or the command line is missing.

## Prerequisites

The `meet42` command line is a separate tool (github.com/Work42-Ai/meet42), not part of the Work42 app. Before relying
on it, check `command -v meet42`: it must print a path. If it prints nothing, or a meet42 command fails
because the tool is missing, ask the user whether to install it (never install it without their yes); if they
agree, follow the `meet42-setup` skill.
