---
name: meet42-setup
description: |
  Install and set up the meet42 command-line tool: download the signed release, install it as ~/.work42/meet42.app with the command linked into ~/.work42/bin, verify it,
  grant its macOS permissions and load the calendar. Use it whenever `command -v meet42` prints nothing, a
  meet42 command fails because the tool is missing or too old, or the user asks to set up or update meet42.
---

# meet42-setup — install and set up meet42

meet42 is a separate, signed and notarized command-line tool (github.com/Work42-Ai/meet42), not part of the
Work42 app. This plugin's widgets and skills call it. Follow these steps in order and stop at the first one that
fails; say what failed instead of working around it.

## 1. Install or update the tool

1. Check what is there: `command -v meet42 && meet42 --version`. `~/.work42/bin` is on `PATH` in Work42 sessions.
   If it prints a version, only continue with this step to update; otherwise install.
2. Download, verify and install the latest release:

   ```bash
   mkdir -p ~/.work42/bin && cd "$(mktemp -d)"
   curl -fsSLO https://github.com/Work42-Ai/meet42/releases/latest/download/meet42.zip
   curl -fsSLO https://github.com/Work42-Ai/meet42/releases/latest/download/meet42.zip.sha256
   shasum -a 256 -c meet42.zip.sha256
   ```

   `shasum` must print `meet42.zip: OK`. If it does not, stop and tell the user; do not install the file.
3. Unpack it (it is a small app bundle, `meet42.app`) and check it is signed by Work42's Developer ID before
   trusting it:

   ```bash
   ditto -x -k meet42.zip .
   codesign --verify --deep --strict meet42.app
   codesign -dv --verbose=2 meet42.app 2>&1 | grep -E "Identifier=com.work42.meet42|TeamIdentifier=74RFQFPVQ9"
   ```

   Both `Identifier` and `TeamIdentifier` lines must print and `--verify` must print nothing. If not, stop and
   tell the user.
4. If a recording is running (`meet42 record status`), do not replace the tool; ask the user to stop it first.
   Otherwise put the app in place and link the command:

   ```bash
   rm -rf ~/.work42/meet42.app && mv meet42.app ~/.work42/meet42.app
   ln -sf ~/.work42/meet42.app/Contents/MacOS/meet42 ~/.work42/bin/meet42
   meet42 --version
   ```

   The app is what macOS knows as "meet42" in System Settings → Privacy & Security.

## 2. Permissions

`meet42 permissions --json` lists `calendar`, `microphone`, `speech` and `systemAudio`. meet42 has its own macOS
identity, so the prompts name meet42, not Work42 or the terminal.

- `not_determined`: run `meet42 permissions request <name>`; macOS shows a prompt. Tell the user to allow it.
- `denied`: macOS will not ask again; ask the user to switch meet42 on in System Settings.
  `meet42 permissions open <name>` opens the right pane.

The **meet42 permissions** widget on an event's Brief tab shows the same four rows with a button each.

## 3. Load the calendar

Run `meet42 sync` once. It reads the calendars the user has added in System Settings → Internet Accounts.

## Done

Tell the user what is installed (`meet42 --version`) and which permissions are still missing, if any.
