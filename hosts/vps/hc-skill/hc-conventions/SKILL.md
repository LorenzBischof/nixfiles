---
name: hc-conventions
description: "This host's conventions for herdr-core (hc): where worktrees go and how they are removed, starting a new agent, starting helpers by role and hearing back, and waiting on a background command such as pr-watch. Use with herdr-core whenever you create a worktree, or start or wait for another agent, helper or background command."
---

# hc on this host

## Worktrees

Create each worktree under `~/.herdr/worktrees`, where Ovis looks; a `/` in the branch name becomes `-` in the folder:

```bash
git -C ~/REPO fetch origin
git -C ~/REPO worktree add ~/.herdr/worktrees/REPO/BRANCH -b BRANCH origin/main
```

When handing work to another agent, create its worktree first and start the agent there with `--cwd`.

When the worktree is clean and its commits are pushed, `git -C ~/REPO worktree remove ~/.herdr/worktrees/REPO/FOLDER`.

## A new agent

```bash
hc run --bg --name NAME --cwd ~/.herdr/worktrees/REPO/FOLDER claude "TASK"
```

Started without labels, it opens in a new tab. `NAME` is the worktree's folder name, lowercased and cut to 32 characters (hc names allow only 1-32 of `a-z 0-9 - _ .`). Tell the user that name.

## Helpers

A role is an hc template, so start a helper with the role as its command, in a hidden pane beside yours, and ask it to report back to you:

```bash
hc-run-hidden --name ROLE ROLE "TASK Report with hc send $HC_TERMINAL_ID."   # note the address it prints, e.g. t7
```

For several at once, start each, then `hc wait --children all`.

The name is for showing only. A finished terminal's name can pass to a new one, so send, wait for, read and remove helpers by the address `hc-run-hidden` prints. Once you have read a helper's report, `hc kill ADDRESS; hc rm ADDRESS`: an idle one still holds its memory. If a name is still taken, add a suffix, e.g. `bug-reviewer-2`.

## Background commands

Start one in a hidden pane beside yours, then wait for it:

```bash
hc-run-hidden --no-notify --name pr-watch pr-watch OWNER/REPO BRANCH   # note the address it prints
hc wait ADDRESS --timeout 1500
```

`--timeout 1500` returns every 25 minutes, so the prompt cache stays warm through a long wait. Its output says why it returned: until that is `"reason":"exit"`, handle what came and wait again. In Claude Code, run the wait with `run_in_background`: a foreground command stops after 10 minutes, and the wait ending wakes you. In Codex, check on the running wait with empty polls of `yield_time_ms` 300000, not shorter: each poll is a turn.

When it exits, `hc read ADDRESS`, then `hc rm ADDRESS`.
