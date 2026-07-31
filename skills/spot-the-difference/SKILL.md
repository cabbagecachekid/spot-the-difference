---
name: spot-the-difference
description: Compare two or more sets of documents and report what differs — values that disagree, sections present in one source and not another, and content stored at a different granularity. Use when the same content lives in more than one place and may have drifted: a document and its published page, a source file and its rendered output, several variants of the same proposal, or a spec and the code that implements it. Also traces where a specific value or phrase still appears across every source, for checking that a change propagated or that retired wording is really gone. Triggers include "what changed between these", "did my edits make it into the render", "spot the difference", "find everywhere I still say X", "compare these versions", "are these in sync".
---

# Spot the difference

Point this at two or more sets of documents. It reports what is different.

The failure it exists to catch: someone settles the wording, then iterates on the
layout, and the words quietly change underneath. By the final render the copy is
not the copy that was approved. Some of the changes are obvious. Some are small
enough to miss and never get changed back.

Everything runs locally. Nothing is uploaded.

## Step 1 — Intake (ask before comparing)

Ask these up front. Skip any the user already answered.

1. **What am I comparing?** Two or more paths. Each can be a file or a folder.
2. **Is one of them the source of truth, or is there no winner?** This decides the
   whole shape of the output — do not guess it.
3. **What counts this run?** Values, structure, prose, or all of them. Default to
   all. If specific terms matter (a product name, a price), collect them as a
   watchlist.
4. **What do you want at the end?** A summary in chat, a written report, or a
   to-do list.

Do not skip question 2. Whether a difference is a *task* or a *decision* depends
entirely on whether something is authoritative, and only the user knows that.

## Step 2 — Run it

`spot.sh` sits beside this file. Invoke it by its full path rather than assuming
a working directory, since an installed plugin is rarely the current directory:

```bash
SPOT=~/.claude/skills/spot-the-difference/spot.sh   # or the plugin's own path

bash "$SPOT" compare --source LABEL=PATH --source LABEL=PATH [--truth LABEL] \
                     [--watch "Term One,Term Two"]
```

Labels are yours to pick; they appear throughout the report, so make them mean
something (`draft` / `published`, not `a` / `b`).

To find where a value or phrase still appears:

```bash
bash "$SPOT" trace --source LABEL=PATH --term "STRING" [--loose]
```

`--loose` tolerates different spacing and punctuation between words, for when the
same thing is written more than one way.

Formats: `.md`, `.txt`, `.html` always; `.pdf` if `pdftotext` is installed;
`.docx` if `pandoc` is installed. Anything skipped is reported with a count,
whether it was skipped for a missing tool or because the file type is not
supported at all. Nothing is dropped in silence.

## Step 3 — Present the results

The raw report is long. Do not paste it whole. Read it and lead with what matters.

**Values first, always.** Prose gets reworded constantly and it is usually fine. A
number, date, or price changing is almost never on purpose. If the values section
has anything in it, that is the headline.

**Then the shape of the report depends on the answer to question 2:**

*A source of truth was named* — everything is directional. Each difference is work
to be done to the other sources: this is missing, this is stale, this contradicts
the approved version. End with a to-do list.

*No source of truth* — stay neutral. Name where the sources disagree and stop
short of saying who is right. End with a decision list, not a to-do list. With
three or more sources, say when two agree and one does not; that is the most
useful thing on the page.

**Read "Stored at a different grain" before reporting a gap.** Sources often
disagree about granularity — one keeps a section per file, another keeps
everything in one document with headings. Items listed there are present in both,
just filed differently. They are usually not findings.

**Check "Needs your eye."** Anything there is a guess the tool is not confident
about. Confirm those with the user rather than reporting them as fact.

## Optional: has the prose drifted toward machine voice?

If the `ai-written-check` skill is available, use it where the report shows an
item's prose changed: read both versions against that checklist and say whether
the change moved *toward* generated-sounding copy. That is the real failure mode
when a section gets regenerated mid-iteration.

This is optional. If that skill is not installed, skip this and say so. Do not
attempt the check from memory, and do not treat its absence as an error.

## Limits

- **Values and headings are compared mechanically. Prose is not.** Reporting how
  wording changed means reading both versions, which is bounded by how much fits
  in context. On large sources, compare a section at a time.
- **Items are files.** Headings within a matched pair are compared, and headings
  register as section keys so a split source can match a combined one — but a
  single long document is not broken into separately-compared items.
- **Last-modified is a fact, not a verdict.** A file that was touched but not
  edited will look newer than it is. Never resolve a disagreement on mtime alone.
- **PDF and plain text carry no heading structure**, so those sources contribute
  values and prose but not structural comparison.
- **Matching is by name, then by heading, then by prefix.** It does not understand
  that "Selected Projects" and "Projects" are the same section. Differences in
  naming show up as findings, which is usually correct but occasionally noise.

## What this does not do

It reports. It does not rewrite, sync, or fix anything, and it does not score
whether a wording change was an improvement. Applying a difference is a separate,
deliberate act.
