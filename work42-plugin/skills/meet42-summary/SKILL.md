---
name: meet42-summary
description: |
  How to build the meeting summary: the "meeting-summary" artifact the Summary widget shows, plus speaker
  attribution. Use it in the Summary stage of a meet42 event session.
---

# meet42-summary — build the meeting summary

The **Summary** widget shows one session artifact, `meeting-summary`, in the same style as the brief. `template.html`
in this folder is a starting point: copy it, replace every example with real content, and drop or add sections when the
meeting calls for it.

## Steps

1. Read the whole transcript (`conversation.jsonl` in the recording directory, from `work42 storage get
   meeting/recording_dir`), the event (`meet42 show "$(work42 storage get meeting/event_id)" --json`) and the
   `meeting-brief` artifact. Read all of the transcript before writing anything.
2. **Attribute speakers.** The transcript names `You`, `Speaker N` and `Them`. For each `Speaker N` you can match to an
   attendee with confidence (addressed by name, introduces themselves, the brief says who owns the topic), write
   `speakers.json` in the recording directory: `{"Speaker 1": {"name": "Marcus Lee", "email": "marcus@acme.com"}}`.
   Leave out any speaker you are unsure about: a wrong name is worse than none. The Recap's transcript then shows names and
   avatars for them. Use the attributed names throughout the summary.
3. Write the artifact: `work42 artifact set meeting-summary --title "Meeting summary"` with your HTML, then
   `work42 artifact status meeting-summary` and fix any error.
4. Count the action items you listed (N) and run `work42 storage set meeting/summary '{"artifact":"meeting-summary","action_items":N}'`,
   then `work42 transition "Done"`.

## Rules

- **Every resource named is a direct link** (issue, pull request, document); an action item links to the issue or PR
  it maps to when there is one.
- Action items have an owner (as an avatar and name), a due date when one was said, and are phrased as something to do.
- Never invent: if something is unclear or missing from the transcript, say so (for example under Open questions).
- Use only Work42's artifact components and `var(--w42-*)` tokens; no network requests, no external scripts or images.
