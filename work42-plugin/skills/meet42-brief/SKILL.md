---
name: meet42-brief
description: |
  How to build the meeting brief: the "meeting-brief" artifact the Meeting brief widget shows. Use it in the
  Prepare for Meeting stage of a meet42 event session.
---

# meet42-brief — build the meeting brief

The **Meeting brief** widget shows one session artifact, `meeting-brief`, full size. Your job in Prepare for Meeting
is to write it so the user walks into the meeting prepared. `template.html` in this folder is a starting point: copy
it, replace every example with real content, and **drop or add sections when the meeting calls for it**. A short,
accurate brief beats a long padded one.

## Steps

1. Read the event: `meet42 show "$(work42 storage get meeting/event_id)" --json` (title, time, location, meeting
   link, organizer, attendees with their replies, description as `notesHTML`). If `meeting/event_id` is unset this is an
   ad-hoc event: say so in the header and skip the people section.
2. Gather context from what this session can reach. Run `work42 widget list`: any other widget the user enabled for
   this session (an issue board, pull requests, docs) has a skill that explains how to read it; use those sources, and
   do not assume which plugins exist. Skip a source whose tool is missing or signed out; say what you skipped.
3. Write the artifact: `work42 artifact set meeting-brief --title "Meeting brief" < template.html` after editing a copy
   (or pipe your own HTML on stdin). Then `work42 artifact status meeting-brief` and fix any error it reports.

## Rules

- **Every resource you mention is a direct link** (issue, pull request, document, thread, the meeting link). Never name
  something the user would have to search for.
- Use only Work42's artifact components and `var(--w42-*)` tokens; no network requests, no external scripts or images.
- Be specific: who is the user meeting, what is each person waiting on, what is the state of each item. No filler.
- Never invent. If you could not find something, leave the section out or say it wasn't found.
- Update the artifact (the same `work42 artifact set`) when the user asks you to rebuild it; the widget reloads itself.
