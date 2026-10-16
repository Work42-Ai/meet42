---
name: meet42-summary
description: |
  How to build the meeting summary: the "meeting-summary" artifact the Summary widget shows, in the same template
  type as the brief (general, standup, refinement, 1:1 or external call), plus speaker attribution. Use it in the
  Summary stage of a meet42 event session.
---

# meet42-summary — build the meeting summary

The **Summary** widget shows one session artifact, `meeting-summary`, in the same visual family as the brief. The
folder `templates/` next to this file has one template per kind of meeting (`general`, `standup`, `refinement`,
`one-on-one`, `external`) built from the Work42 design kit (Tailwind classes, `wk-*` recipes and SF Symbols).

## Steps

1. Read the whole transcript (`conversation.jsonl` in the recording directory, from `work42 storage get
   meeting/recording_dir | tr -d '"'`), the event (`meet42 show "$(work42 storage get meeting/event_id | tr -d '"')" --json`)
   and the `meeting-brief` artifact. Storage values print as JSON strings in quotes; `tr -d '"'` strips them.
   To link an issue or pull request someone mentioned, look it up with the CLIs of the session's data-source widgets
   (`work42 widget list`, open or closed, load each skill) rather than guessing a URL. Read all of the transcript before writing anything. Each transcript line has
   `audioStartSeconds`: use it for the `mm:ss` times on decisions, concerns and key moments.
2. **Pick the same template type as the brief** (its eyebrow says "Standup brief", "1:1 brief", …). If there is no
   brief, choose by the event as the brief skill describes, and use `general` when none fits.
3. **Attribute speakers.** The transcript names `You`, `Speaker N` and `Them`. For each `Speaker N` you can match to an
   attendee with confidence (addressed by name, introduces themselves, the brief says who owns the topic), write
   `speakers.json` in the recording directory: `{"Speaker 1": {"name": "Marcus Lee", "email": "marcus@acme.com"}}`.
   Leave out any speaker you are unsure about: a wrong name is worse than none. The Recap's transcript then shows names and
   avatars for them. Use the attributed names throughout the summary.
4. Build the artifact. `D` is the folder this SKILL.md is in:
   ```bash
   D=<the folder this SKILL.md is in>
   cp "$D/templates/<type>.html" /tmp/meeting-summary.html
   ```
   Edit `/tmp/meeting-summary.html`: replace every example with real content, drop sections with nothing real in them,
   and remove the leading guidance comment. There is no stylesheet to add and no colour to set. Then
   `work42 artifact set meeting-summary /tmp/meeting-summary.html --title "Meeting summary"` and
   `work42 artifact status meeting-summary`, and fix anything it reports: `set` must print no lint findings.
5. Count the action items you listed (N) and run `work42 storage set meeting/summary '{"artifact":"meeting-summary","action_items":N}'`,
   then `work42 transition "Done"`.

## Avatars

Owners and speakers get a round initials avatar. The templates show the exact markup; only the colour depends on the
person. It must match the widgets: it comes from their email
(else their name), lowercased, with FNV-1a modulo 6. Compute the number with:

```bash
python3 -c 'import sys;h=0xcbf29ce484222325;[h:=((h^b)*0x100000001b3)&0xFFFFFFFFFFFFFFFF for b in sys.argv[1].lower().encode()];print(h%6)' "ana@acme.com"
```

and use the colour classes for that number. Avatars follow the Apple look: one solid system colour with a soft sheen on top,
so every avatar is `<colour> bg-gradient-to-b from-on-accent/25 to-transparent`:

| n | colour class |
| -- | -- |
| 0 | `bg-danger` |
| 1 | `bg-accent` |
| 2 | `bg-success` |
| 3 | `bg-warning` |
| 4 | `bg-info` |
| 5 | `bg-label-tertiary` |

Sizes: `size-[22px] text-2xs` for owners, `size-7 text-xs` for update rows, `size-9 text-md` for people lists and stacks, `size-10 text-xl` for the 1:1 header.
Initials are the first letters of the first and last word of the name (else the first two letters of the email).

## Rules

- **Every resource named is a direct link** (issue, pull request, document); an action item links to the issue or PR
  it maps to when there is one.
- Action items have an owner (as an avatar and name), a due date when one was said ("No date" otherwise), and are phrased
  as something to do.
- Never invent: if something is unclear or missing from the transcript, say so (for example under Open questions). Times
  come from the transcript, never from memory.
- Style only with the Tailwind classes and `wk-*` recipes the templates use (see the `work42-artifact` skill): semantic
  colours, the type scale and `<i data-sf="…">` SF Symbols; never a hex colour, a palette class or an arbitrary font size.
  No network requests, no external scripts, fonts or images.
