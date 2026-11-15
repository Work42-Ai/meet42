# meet42

A local, private meeting tool for macOS: it reads your calendar, records and transcribes a meeting on-device
(including the other side of the call), and remembers who you meet. It is a command-line tool that any agent
or script can drive, and it ships with an optional [Work42](https://github.com/work42-ai/work42) plugin that puts
it inside Work42 sessions.

Nothing leaves your Mac: audio is transcribed on-device, and the calendar and people data stay in
`~/.work42/meet42`.

## Install

meet42 is distributed only inside [Work42](https://github.com/work42-ai/work42): there is no standalone download. The
Work42 app embeds a separately signed, notarized `meet42.app` (no window and no Dock icon; the command-line tool is its
executable), copies it to `~/.work42/meet42.app` at launch, links the command at `~/.work42/bin/meet42`, installs this
plugin as a built-in, and updates all of it with the app. macOS shows its permission prompts only for an app bundle,
and they name "meet42".

Add `~/.work42/bin` to your shell `PATH` if you use meet42 outside Work42 (Work42 puts it on `PATH` for its agent
sessions and widget commands).

## Permissions

meet42 asks macOS for four permissions, each shown under the name **meet42** (it has its own signature):

| Permission | Used for |
|------------|----------|
| Calendar | list meetings and prepare sessions |
| Microphone | record meeting audio locally |
| Speech recognition | on-device transcription |
| System audio recording only | hear the other side of a call (meet42 never records your screen) |

```bash
meet42 permissions                       # status of all four
meet42 permissions request microphone    # show macOS's prompt for one
meet42 permissions open systemAudio      # open its System Settings page
```

macOS asks only once per permission; one that was denied is switched on in System Settings.
`meet42 permissions --json` prints `[{"name":"calendar","status":"granted"},…]` with
statuses `granted`, `denied`, `not_determined` and `restricted`.

`meet42 show <event_id|next> --json` returns the event as stored plus `notesHTML` (the notes as sanitised HTML:
formatting tags and http/https/mailto links only) and `calendarColor` (`#RRGGBB`, once synced). Calendar sync never
deletes an event that is linked to a session.

## Use

```bash
meet42 today                      # today's events
meet42 next --json                # the next meeting
meet42 record start --manual     # record and transcribe; `record stop` finishes it
meet42 help                       # every verb
```

## The Work42 plugin

`work42-plugin/` is the Work42 plugin: an `event` session type, a meeting workflow, and widgets for event
details (with the guest list), recording, annotations, the calendar, and a **meet42 permissions** tile that shows
the four permissions above and lets you grant each. Its Brief and Recap tabs show the meeting's brief and summary as
artifact tiles (they appear once the agent writes them). It is built in to Work42: it is installed by the app at launch,
can't be removed or updated on its own, and is pinned by git tag in Work42's `BuiltInPlugins.json`. Ask the agent in any
Work42 session to set up meet42: it follows the plugin's `meet42-setup` skill, which checks the tool and walks you through
the permissions.

## Develop

```bash
swift build --product meet42        # debug build (ad-hoc signed: permission grants don't persist)
swift test                          # unit tests
scripts/build-meet42.sh             # release build, signed when DEVELOPER_ID is set
```

An ad-hoc signed build has no stable identity, so macOS forgets permission grants on every rebuild. Test
permission *prompts* with a build signed by `scripts/release.sh`. (meet42 re-executes itself with macOS's
"disclaim responsibility" attribute for the verbs that touch permissions, so it reports and asks for its own
permissions, not those of the terminal or app that launched it; `MEET42_NO_DISCLAIM=1` turns that off.)

## Release

**Between releases**, ship a fix to your own Mac with one command. It builds this checkout, signs it with your
Developer ID (the same identity as the installed app, so macOS keeps meet42's permission grants) and swaps it in
as `~/.work42/meet42.app`; a running recording is not affected, and the previous build stays at
`~/.work42/meet42.app.prev`:

```bash
scripts/install-local.sh
```


A release is a git tag (`v<version>`) that Work42 pins in `app/BuiltInPlugins.json`; the Work42 app build checks it out,
builds `meet42.app` with `scripts/build-meet42.sh` and embeds it. Nothing is published as a standalone download.
`scripts/release.sh` is the local check that a version signs, notarizes and runs:

```bash
cp .env.release.example .env.release.local      # fill in your Developer ID and notary profile
scripts/release.sh 0.1.0 --check                # what is ready, what is blocked
scripts/release.sh 0.1.0                        # build, sign, notarize a candidate in dist/0.1.0
```

The version is the `meet42Version` constant in `Sources/meet42/main.swift`; the release script refuses to run
if it disagrees with the version you pass.

## Origin

Extracted from [`work42-plugins`](https://github.com/Work42-Ai/work42-plugins) (`meet42-cli/` and `meet42/`).

## License

MIT, see [LICENSE](LICENSE).
