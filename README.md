# meet42

A local, private meeting tool for macOS: it reads your calendar, records and transcribes a meeting on-device
(including the other side of the call), and remembers who you meet. It is a command-line tool that any agent
or script can drive, and it ships with an optional [Work42](https://github.com/work42-ai/work42) plugin that puts
it inside Work42 sessions.

Nothing leaves your Mac: audio is transcribed on-device, and the calendar and people data stay in
`~/.work42/meet42`.

## Install

Download the latest signed, notarized release, check its checksum, and put it in `~/.work42/bin`
(Work42 puts that folder on `PATH` for its agent sessions and widget commands):

```bash
mkdir -p ~/.work42/bin && cd "$(mktemp -d)"
curl -fsSLO https://github.com/Work42-Ai/meet42/releases/latest/download/meet42.zip
curl -fsSLO https://github.com/Work42-Ai/meet42/releases/latest/download/meet42.zip.sha256
shasum -a 256 -c meet42.zip.sha256          # must print: meet42.zip: OK
ditto -x -k meet42.zip ~/.work42/bin/
meet42 --version
```

Add `~/.work42/bin` to your shell `PATH` if you use meet42 outside Work42.

## Permissions

meet42 asks macOS for four permissions, each shown under the name **meet42** (it has its own signature):

| Permission | Used for |
|------------|----------|
| Calendar | list meetings and prepare sessions |
| Microphone | record meeting audio locally |
| Speech recognition | on-device transcription |
| Screen & system audio recording | hear the other side of a call |

```bash
meet42 permissions                       # status of all four
meet42 permissions request microphone    # show macOS's prompt for one
meet42 permissions open screen           # open its System Settings page
```

macOS asks only once per permission; one that was denied is switched on in System Settings. Screen & system
audio has no prompt at all: switch meet42 on under *Privacy & Security → Screen & System Audio Recording* and
start meet42 again. `meet42 permissions --json` prints `[{"name":"calendar","status":"granted"},…]` with
statuses `granted`, `denied`, `not_determined` and `restricted`.

## Use

```bash
meet42 today                      # today's events
meet42 next --json                # the next meeting
meet42 record start --manual     # record and transcribe; `record stop` finishes it
meet42 help                       # every verb
```

## The Work42 plugin

`work42-plugin/` is the Work42 plugin: an `event` session type, a meeting workflow, and widgets for event
details, people, recording, annotations, summary, the calendar, and a **meet42 permissions** tile that shows
the four permissions above and lets you grant each. Install it from this repository:

```bash
work42 plugin install https://github.com/Work42-Ai/meet42 --path work42-plugin
```

then press **Set up** on it in Work42's Settings → Plugins (or run `work42 plugin setup meet42`): a chat session
installs the tool above and walks you through the permissions, following the plugin's own skills.

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

```bash
cp .env.release.example .env.release.local      # fill in your Developer ID and notary profile
scripts/release.sh 0.1.0 --check                # what is ready, what is blocked
scripts/release.sh 0.1.0                        # build, sign, notarize a candidate in dist/0.1.0
scripts/release.sh 0.1.0 --publish              # create GitHub release v0.1.0 with the two assets
```

The version is the `meet42Version` constant in `Sources/meet42/main.swift`; the release script refuses to run
if it disagrees with the version you pass.

## Origin

Extracted from [`work42-plugins`](https://github.com/Work42-Ai/work42-plugins) (`meet42-cli/` and `meet42/`).

## License

MIT, see [LICENSE](LICENSE).
