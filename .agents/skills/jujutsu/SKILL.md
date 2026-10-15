---
name: jujutsu
description: Use jj (Jujutsu) for all VCS operations in this repository, including status, diffs, history, commits, and publishing. Git is colocated; jj owns the working copy.
---

# Jujutsu (jj)

Use jj, not `git status`, `git diff`, `git add`, `git commit`, or `git stash`.

## Workflow

1. Inspect `jj status` and recent history. Work in an empty `@`; run `jj new` if it already contains work. Preserve existing edits.
2. Make edits, then run `jj absorb`. Never rewrite pushed changes; exclude them explicitly if the repository's mutable set includes them.
3. Review `jj op show -p` and the remaining diff. Absorb follows line history, not task intent: use `jj undo` for misplaced edits and `jj squash --into <rev>` to consolidate related unpushed work and leftovers. Prefer one coherent change per task; keep unrelated work separate.
4. Describe remaining work and broaden affected ancestors' descriptions with `jj describe [-r <rev>] -m "scope: message"`. Match existing lowercase prefixes (`ai:`, `firefox:`, …) and use imperative wording. Leave the fresh change undescribed until absorption so jj can abandon it if fully absorbed.

When publishing is requested, point `main` at the intended tip with `jj bookmark set main -r <rev>`, then `jj git push`. Use `@-` when `@` is empty, otherwise `@`.

## Diffs and reporting

Use `jj diff --from 'trunk()'` for all unpushed work and `jj log -r 'trunk()::@'` for its history.

When including a change list, preserve newest-first order and use `change_id.shortest()` rather than fixed-width IDs or Git hashes. Summarize history mutations in prose rather than annotating log lines. This compact query includes empty changes and bookmarks:

```
jj log -r 'trunk()::@' --no-graph -T '
  if(current_working_copy, "@", " ") ++ " " ++
  change_id.shortest() ++
  if(bookmarks, " [" ++ bookmarks.join(",") ++ "]") ++ " " ++
  if(empty, "(empty) ", "") ++
  if(description, description.first_line(), "(no description)") ++ "\n"
'
```
