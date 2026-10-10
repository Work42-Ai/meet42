---
name: meet42-brief
description: |
  How to build the meeting brief: the "meeting-brief" artifact the Meeting brief widget shows, in the template that
  fits the meeting (general, standup, refinement, 1:1 or external call). Use it in the Prepare for Meeting stage of
  a meet42 event session.
---

# meet42-brief — build the meeting brief

The **Meeting brief** widget shows one session artifact, `meeting-brief`, full size. Your job in Prepare for Meeting
is to write it so the user walks into the meeting prepared. Pick the template that fits the meeting, fill it with real
content, and **drop sections that have nothing real in them**. A short, accurate brief beats a long padded one.

## Pick the template

The folder `templates/` next to this file has one template per kind of meeting, all sharing `templates/style.css`.
Choose from what the event shows (title, recurrence, attendees, their email domains, the description). This is
judgement, not a rule: if none clearly fits, use `general`.

| Template | Use it for |
| -- | -- |
| `standup.html` | A short recurring meeting with teammates only; "standup", "daily", "sync" in the title. |
| `refinement.html` | "Refinement", "grooming", "planning" or "backlog" in the title, or issue keys in the invite. |
| `one-on-one.html` | Exactly one other attendee, usually recurring; "1:1" or "1-on-1" in the title. |
| `external.html` | Any attendee on an email domain other than the user's (a customer, partner or candidate). |
| `general.html` | Everything else, and ad-hoc events. |

The brief's eyebrow names its type ("Standup brief"); the summary stage uses the same type, so keep that wording.

## Steps

1. Read the event: `meet42 show "$(work42 storage get meeting/event_id)" --json` (title, time, location, meeting
   link, organizer, attendees with their replies, `calendarColor`, description as `notesHTML`). If `meeting/event_id`
   is unset this is an ad-hoc event: use `general`, say so in the hero, and skip the guest section.
2. Gather context from what this session can reach. Run `work42 widget list`: any other widget the user enabled for
   this session (an issue board, pull requests, docs) has a skill that explains how to read it; use those sources, and
   do not assume which plugins exist. Skip a source whose tool is missing or signed out and say what you skipped in the
   footer. For a 1:1 or external call, also look for the earlier summary of the same meeting and the last emails with
   those people if a connector offers them.
3. Build the artifact from the template. `D` is the folder this SKILL.md is in:
   ```bash
   D=<the folder this SKILL.md is in>
   { echo '<style>'; cat "$D/templates/style.css"; echo '</style>'; cat "$D/templates/<type>.html"; } > /tmp/meeting-brief.html
   ```
   Edit `/tmp/meeting-brief.html`: replace every example with real content, remove the leading `<!-- … -->` guidance
   comments, and set `--acc` on the `<div class="m" style="--acc:…">` wrapper to the event's `calendarColor` when it has
   one. Then `work42 artifact set meeting-brief /tmp/meeting-brief.html --title "Meeting brief"` and
   `work42 artifact status meeting-brief`, and fix any error it reports.

## Avatars

Guests and owners get a round initials avatar, `<span class="m-av g0">AS</span>` (add `sm` for a small one, `lg` for
the 1:1 header). The colour class `g0` to `g5` must match what the widgets show for the same person: it comes from their
email (else their name), lowercased, with FNV-1a modulo 6. Compute it with:

```bash
python3 -c 'import sys;h=0xcbf29ce484222325;[h:=((h^b)*0x100000001b3)&0xFFFFFFFFFFFFFFFF for b in sys.argv[1].lower().encode()];print(h%6)' "ana@acme.com"
```

and use `g` plus the number. Initials are the first letters of the first and last word of the name (else the first two
letters of the email).

## Rules

- **Every resource you mention is a direct link** (issue, pull request, document, thread, the meeting link). Never name
  something the user would have to search for.
- Use only the classes in `templates/style.css`, `var(--w42-*)` tokens and inline SVG. No network requests, no external
  scripts, fonts or images, and no tokens the theme doesn't define.
- Be specific: who is the user meeting, what is each person waiting on, what is the state of each item. No filler.
- Never invent. If you could not find something, leave the section out or say it wasn't found.
- Update the artifact (the same `work42 artifact set`) when the user asks you to rebuild it, including in another
  template ("use the 1:1 template"); the widget reloads itself.
