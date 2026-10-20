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

## Splitting one change into several

`jj split` is non-interactive when given filesets and `-m`, and `-A`/`-B`/`-o` extract the *selected* paths into a new commit at that location while the remainder stays where it is. So carve one large change bottom-up, one command per piece:

```
jj split -r <holding> -A <parent> -m "scope: first piece" path/a path/b
jj split -r <holding> -A '@-'     -m "scope: second piece" path/c
```

The remainder is then a worklist that shrinks on its own — nothing to track by hand, and no second head to reconcile. The last piece needs no split at all: `jj describe -r <holding>`, since splitting an empty commit is refused.

Where the new commit lands also decides what is on disk: extracting to a location *above* `@` (`-A '@'`) takes those paths out of the working-copy change, so jj rewrites the files on disk to their pre-edit state and the content survives only in the new commit — which surprises anything still holding those files, an editor or a concurrent agent. Keep extracted pieces at or below `@` (`-B '@'`, `-A '@-'`) and the working copy keeps the final text. `jj undo` restores the commit and the files together.

Filesets are per-file, so a file whose hunks belong to different pieces needs hand-editing — make the edit at a child change and `jj squash --into <rev>`. Restore the *final* version of such a file and revert the hunks that belong later, rather than editing the base forward: the final text is authoritative, so nothing has to be retyped.

Order the pieces by dependency, and put independent fixes lowest so they can be published without the rest. Evaluate the intermediate revisions too, not just the tip — a piece that does not build on its own is not a piece.

## jj undo reaches further than it looks

Every jj invocation snapshots the working copy first, `jj undo` included: it records its own `snapshot working copy` operation and then undoes that. So a bad edit is recoverable even with no jj command in between, and undo rewrites the files on disk, not just the commit. It also reverts the rebases a `jj squash --into` triggered, and `jj op log` plus `jj op restore <id>` reaches back further than one step. Untracked files are never snapshotted, so undo will not bring back one that was clobbered.

Do not work defensively around history edits: `jj edit <rev>` on a revision with descendants, an in-place `jj split`, and a squash that rebases descendants are all undoable. Building a parallel chain of changes and proving it equal to the original before abandoning it is wasted effort.

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
