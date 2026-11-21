---
name: work-log
description: Use when asked to summarize what the user worked on, and when, on a given day (or "today"/"yesterday"). Covers Claude Code and Codex sessions.
---

# Work log

Run `work-log-extract --date YYYY-MM-DD` (date optional, defaults to today). It
prints a short Markdown timeline of that day's Claude Code and Codex
sessions — who said what, grouped by project and time, with long messages
shortened.

Never read the raw logs under `~/.claude/projects` or `~/.codex/sessions`
directly — they are huge and will exhaust context.

If one session's summary looks cut short and you need the full text, re-run
with `--max-chars 100000` (still much smaller than the raw logs).

Read the command's output and report it as:

1. A Markdown table with columns Time, Tool, Project, What happened — one row
   per block in the output, using its exact `HH:MM-HH:MM` range. Before
   writing the table, count the `## HH:MM-HH:MM` headers in the output — the
   table must have exactly that many rows, in the same order. A dropped last
   block is the most common failure, especially when the day has a late,
   short block after a gap.
2. A short plain-language summary below the table (a few sentences, not a
   section per time-of-day).

Fill in each row right after reading its own heading, using only the text
under that heading. Two blocks can share the same project name (e.g. two
`nixfiles` sessions hours apart) — match content by time range, never by
project, and don't let one block's content bleed into another's row.

Never invent labels like "morning"/"afternoon"/"evening" or group blocks under
them — a session's actual time range already says when it happened, and
labeling periods invites inferring activity in gaps where the output shows
none. Only state times, projects, and activity that literally appear in the
command's output; if a stretch of the day has no blocks, that means no agent
session happened then — don't fill it in by extrapolating from other days.
