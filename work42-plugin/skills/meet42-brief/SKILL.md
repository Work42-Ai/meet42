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

The folder `templates/` next to this file has one template per kind of meeting, all built from the Work42 design kit (Tailwind classes, `wk-*` recipes and SF Symbols).
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

1. Read the event: `meet42 show "$(work42 storage get meeting/event_id | tr -d '"')" --json` (title, time, location,
   meeting link, organizer, attendees with their replies, `calendarColor`, description as `notesHTML`). Storage values
   print as JSON, so a string comes back in quotes; `tr -d '"'` strips them, and without it `meet42 show` finds no event.
   If `meeting/event_id` is unset this is an ad-hoc event: use `general`, say so in the hero, and skip the guest section.
2. Gather context from the session's data sources **before you write anything**. Run `work42 widget list`: every
   widget in it other than the meeting's own (chat, recording, brief, event details, summary, permissions, annotations)
   is a data source, **whether it is open or closed** (an issue board, pull requests, docs). For each one, load its skill
   and run the commands it names (a CLI such as an issue tracker or a code host) to find the items that relate to this
   meeting. A source is unavailable only when those commands fail: an MCP connector that is not authorized is not a
   reason to skip a source whose CLI works. Do not assume which plugins exist. Say in the footer which sources you read
   and which failed. For a 1:1 or external call, also look for the earlier summary of the same meeting and the last emails with
   those people if a connector offers them.
3. Build the artifact from the template. `D` is the folder this SKILL.md is in:
   ```bash
   D=<the folder this SKILL.md is in>
   cp "$D/templates/<type>.html" /tmp/meeting-brief.html
   ```
   Edit `/tmp/meeting-brief.html`: replace every example with real content and remove the leading `<!-- … -->`
   guidance comments. The page is plain Tailwind and kit markup; there is no stylesheet to add and no colour to set
   (the accent follows the app). Then `work42 artifact set meeting-brief /tmp/meeting-brief.html --title "Meeting brief"`
   and `work42 artifact status meeting-brief`, and fix anything it reports: `set` must print no lint findings.

## Avatars

Guests and owners get a round initials avatar. The templates show the exact markup; only the colour depends on the
person. Pick one of six colours so it matches what the widgets show for the same person: it comes from their email
(else their name), lowercased, with FNV-1a modulo 6. Compute the number with:

```bash
python3 -c 'import sys;h=0xcbf29ce484222325;[h:=((h^b)*0x100000001b3)&0xFFFFFFFFFFFFFFFF for b in sys.argv[1].lower().encode()];print(h%6)' "ana@acme.com"
```

and use the colour for that number. Avatars match the widgets: a tinted glass circle in one plain colour with the
initials in that same colour. Keep the template's size and layout classes and set the colour classes from this table:

| n | colour | classes |
| -- | -- | -- |
| 0 | red | `bg-danger/20 text-danger ring-1 ring-inset ring-danger/30 backdrop-blur-md` |
| 1 | blue | `bg-accent/20 text-accent ring-1 ring-inset ring-accent/30 backdrop-blur-md` |
| 2 | green | `bg-success/20 text-success ring-1 ring-inset ring-success/30 backdrop-blur-md` |
| 3 | amber | `bg-warning/20 text-warning ring-1 ring-inset ring-warning/30 backdrop-blur-md` |
| 4 | teal | `bg-info/20 text-info ring-1 ring-inset ring-info/30 backdrop-blur-md` |
| 5 | grey | `bg-label-tertiary/20 text-label-secondary ring-1 ring-inset ring-label-tertiary/30 backdrop-blur-md` |

Overlapping avatars (a stack, `-ml-2 first:ml-0`) get a solid backing so they do not show through each other: replace the
colour classes with `bg-backdrop bg-gradient-to-b from-<c>/20 to-<c>/20 text-<c> outline outline-2 outline-backdrop`,
where `<c>` is the colour name from the table (`danger`, `accent`, `success`, `warning`, `info`, `label-tertiary`; the
text of the grey one is `text-label-secondary`). Never use white initials or a solid-colour fill.

Sizes: `size-[22px] text-2xs` for owners, `size-7 text-xs` for update rows, `size-9 text-md` for people lists and stacks, `size-10 text-xl` for the 1:1 header.
Initials are the first letters of the first and last word of the name (else the first two letters of the email).

## Rules

- **Every resource you mention is a direct link** (issue, pull request, document, thread, the meeting link). Never name
  something the user would have to search for.
- Style only with the Tailwind classes and `wk-*` recipes the templates use (see the `work42-artifact` skill for the full
  vocabulary): semantic colours (`text-label`, `bg-card`, `text-success-ink`), the type scale (`text-md`, `text-lg`), and
  `<i data-sf="…">` SF Symbols. Never a hex colour, a palette class (`bg-blue-500`, `text-white`) or an arbitrary font size.
  No network requests, no external scripts, fonts or images.
- Be specific: who is the user meeting, what is each person waiting on, what is the state of each item. No filler.
- Never invent. If you could not find something, leave the section out or say it wasn't found.
- Update the artifact (the same `work42 artifact set`) when the user asks you to rebuild it, including in another
  template ("use the 1:1 template"); the widget reloads itself.
