---
name: jujutsu
description: Use for any VCS operation in this repo — checking status/changes, diffs, committing, branching, or inspecting history. It's managed with jj (Jujutsu) colocated over git, so `git status`/`git diff`/`git commit` are wrong; use jj instead.
---

# Jujutsu (jj)

Colocated jj-over-git. Never `git commit` / `git add` / `git stash` — jj owns the working copy.

## Repo conventions

- **Start each task with `jj new`.** Your work belongs in its own change, not mixed into the user's working copy. Never `jj edit` into a change you didn't create.
- **Redescribe freely.** `jj describe -m "scope: msg"` overwrites the message on `@` at any time — set a rough one as soon as you know the gist, then refine as the scope sharpens. Don't wait until "done."
- **Commit-message prefix style:** match existing `jj log` prefixes (`ai:`, `firefox:`, …) — short, lowercase prefix, imperative.
- **Publish flow:** `jj bookmark set main -r @-`, then `jj git push`. (Push only moves bookmarks; without `set` first, your commits stay local.)

## "What changed" — canonical forms

When the user asks for diffs or current changes, use the trunk-relative form:

- `jj diff --from 'trunk()'` — full diff of unpushed work (committed + working copy; `--to` defaults to `@`).
- `jj log -r 'trunk()::@'` — same range as commits, with trunk tip as anchor.

## Absorb footgun

`jj absorb` routes hunks into the ancestor that last touched those lines. Fine for isolated fixes; for restructuring, prefer `jj squash --into <rev>` — adjacent-line hunks can land in the wrong commit. `jj undo` reverses cleanly.

## Reporting back

When summarizing jj output, run the canonical query below and mirror its output verbatim. jj log is reverse-chronological — newest at top.

```
jj log -r 'trunk()::@' --no-graph -T '
  if(current_working_copy, "@", " ") ++ " " ++
  change_id.shortest() ++
  if(bookmarks, " [" ++ bookmarks.join(",") ++ "]") ++ " " ++
  if(empty, "(empty) ", "") ++
  if(description, description.first_line(), "(no description)") ++ "\n"
'
```

Use `change_id.shortest()` — the minimal unique prefix jj itself bolds. Don't substitute fixed-width short IDs or git hashes.

When you mutate history this turn (`describe`, `squash`, `abandon`, `new`, `rebase`, etc.), precede the log with a one-line prose summary — e.g. `Redescribed w.` — instead of annotating individual log lines.

Example output (after redescribing `w` this turn):

```
Redescribed w.

@ u (empty) (no description)
  s ai: add jujutsu skill
  z ai: remote control dispatch
  w ai: integrate fastflowlm + lemonade-ai on framework
  v [main] firefox: silence warning about configPath
```
