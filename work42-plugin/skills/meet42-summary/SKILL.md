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

1. Read the whole transcript (`conversation.jsonl` in the recording directory, from `storage_get
   meeting/recording_dir | tr -d '"'`), the event (`meet42 show <event id> --json` (the event id is the `storage_get` value for key `meeting/event_id`))
   and the `meeting-brief` artifact. Storage values print as JSON strings in quotes; `tr -d '"'` strips them.
   To link an issue or pull request someone mentioned, look it up with the CLIs of the session's data-source widgets
   (`widget_list`, open or closed, load each skill) rather than guessing a URL. Read all of the transcript before writing anything. Each transcript line has
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
   `artifact_set` and
   `artifact_status`, and fix anything it reports: `set` must print no lint findings.
5. Count the action items you listed (N) and run `storage_set` (key `meeting/summary`),
   then call the `transition` tool with target "Done".

## Avatars

Owners and speakers get a round initials avatar. The templates show the exact markup; only the colour depends on the
person. It must match the widgets: it comes from their email
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

- **Every resource named is a direct link** (issue, pull request, document); an action item links to the issue or PR
  it maps to when there is one.
- Action items have an owner (as an avatar and name), a due date when one was said ("No date" otherwise), and are phrased
  as something to do.
- Never invent: if something is unclear or missing from the transcript, say so (for example under Open questions). Times
  come from the transcript, never from memory.
- Style only with the Tailwind classes and `wk-*` recipes the templates use (see the `work42-artifact` skill): semantic
  colours, the type scale and `<i data-sf="…">` SF Symbols; never a hex colour, a palette class or an arbitrary font size.
  No network requests, no external scripts, fonts or images.
