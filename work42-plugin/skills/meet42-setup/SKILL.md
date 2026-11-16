---
name: meet42-setup
description: |
  Set up the meet42 command-line tool that ships with Work42: check it is there, grant its macOS permissions and load the calendar.
  Use it whenever a meet42 command fails because the tool is missing, a permission is not granted, or the user asks to set up
  meet42.
---

# meet42-setup — set up meet42

meet42 ships inside Work42: the app installs `~/.work42/meet42.app` (with the command linked at `~/.work42/bin/meet42`) at
every launch and updates it with the app. It has its own macOS identity, so its permission prompts name meet42. This plugin's
widgets and skills call it. **Never download or install it yourself.** Follow these steps in order and stop at the first one
that fails; say what failed instead of working around it.

## 1. Check the tool

Run `command -v meet42 && meet42 --version`. `~/.work42/bin` is on `PATH` in Work42 sessions.

If it prints nothing, or a command says the tool is too old, Work42 has not installed or updated it yet. Tell the user to
quit and reopen Work42 (it installs meet42 at launch), or to update or reinstall Work42 if that does not help. Do not
fetch meet42 from anywhere else.

## 2. Permissions

`meet42 permissions --json` lists `calendar`, `microphone`, `speech` and `systemAudio`. meet42 has its own macOS
identity, so the prompts name meet42, not Work42 or the terminal.

- `not_determined`: run `meet42 permissions request <name>`; macOS shows a prompt. Tell the user to allow it.
- `denied`: macOS will not ask again; ask the user to switch meet42 on in System Settings.
  `meet42 permissions open <name>` opens the right pane.

When any permission is not granted, open the **meet42 permissions** widget for the user with `widget_open` (id `w_widget_permissions`) (it is listed for event sessions but on no tab) and walk them through its four rows: each has a button, **Request** for a permission macOS hasn't asked about yet and **Open Settings** for the rest.

## 3. Load the calendar

Run `meet42 sync` once. It reads the calendars the user has added in System Settings → Internet Accounts.

## Done

Tell the user what is installed (`meet42 --version`) and which permissions are still missing, if any.
