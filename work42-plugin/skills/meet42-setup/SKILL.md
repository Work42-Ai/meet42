---
name: meet42-setup
description: |
  Set up meet42 as it ships with Work42: check the command line is there, check the permissions Work42 holds for it, and make sure the
  calendar is loaded. Use it whenever a meet42 command fails because the tool is missing, a permission is not granted, or the user
  asks to set up meet42.
---

# meet42-setup — set up meet42

meet42 ships inside Work42: the app installs `~/.work42/meet42.app` (with the command linked at `~/.work42/bin/meet42`) at
every launch and updates it with the app. **The command line holds no macOS permission.** Work42 holds the microphone,
system-audio, calendar and speech-recognition permissions for the meet42 plugin and does the recording, transcribing and
calendar reading itself, so every prompt and every System Settings switch names **Work42**. This plugin's widgets and skills call the
command line to read what Work42 collected. **Never download or install it yourself.** Follow these steps in order and stop at
the first one that fails; say what failed instead of working around it.

## 1. Check the tool

Run `command -v meet42 && meet42 --version`. `~/.work42/bin` is on `PATH` in Work42 sessions. It should say 2.0.0 or later.

If it prints nothing, or a command says the tool is too old, Work42 has not installed or updated it yet. Tell the user to
quit and reopen Work42 (it installs meet42 at launch), or to update or reinstall Work42 if that does not help. Do not
fetch meet42 from anywhere else.

## 2. Permissions

There is no `meet42 permissions` command any more. The four permissions are Calendar, Microphone, Speech recognition and
System audio, and the **meet42 permissions** widget shows where each stands and acts on it.

Open that widget for the user with `widget_open` (id `w_widget_permissions`) (it is listed for event sessions but on no tab)
and walk them through its four rows. Each has a button: **Grant** for a permission nobody has been asked about yet (Work42
shows its own pill, then macOS's prompt; tell the user to allow it) and **Open Settings** for the rest. A permission macOS
has denied is not asked again: the user switches **Work42** on in System Settings → Privacy & Security.

## 3. The calendar

Work42 reads the calendars once Calendar is granted and keeps meet42's own copy current by itself (at start, when the calendars
change, and every five minutes). There is nothing to run. If `meet42 list` shows nothing after Calendar is granted, wait a
minute and look again; do not run `meet42 sync` (it needs an events file Work42 writes).

## Done

Tell the user what is installed (`meet42 --version`) and which permissions are still missing, if any.
