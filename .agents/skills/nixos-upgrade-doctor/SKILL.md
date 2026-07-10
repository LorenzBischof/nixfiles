---
name: nixos-upgrade-doctor
description: Use when a host's NixOS auto-upgrade (nixos-upgrade.service) is stuck, skipped, or not applying — especially when the guard reports the deployed commit is missing on GitHub. Points at the diagnosis script and shows how to dig into what actually changed with jj.
---

# NixOS upgrade doctor

`nixos-upgrade.service` runs an `ExecCondition` guard (`modules/nixos/autoupgrade.nix`)
that compares the running revision against the default branch via the GitHub API
*before* building. If the deployed commit isn't cleanly on `main`, the guard exits
non-zero and the upgrade is **skipped every run** — the service reads
"inactive (dead) (Result: exec-condition)", which looks broken but is the guard
doing its job.

## First, run the script

```bash
just upgrade-doctor              # this machine (framework), no SSH
just upgrade-doctor nas          # or vps — over SSH
```

It prints a short narrative: what's deployed (hash + message), what happened to it,
and the fix. Usually that's the whole answer.

- **Remote hosts need a non-sandboxed claude.** The local (no-arg) form needs no
  SSH. For a remote host, the `claude-bwrap` sandbox (`modules/home/ai/default.nix`)
  gives `~/.ssh` no config/known_hosts/agent, so SSH fails and the script exits 3.
  Relaunch the plain `claude` binary (not `claude-bwrap`) and re-run. To analyse a
  known rev without SSH: `scripts/nixos-upgrade-doctor.sh --rev <sha> <host>`.

## When the output is unclear: dig with jj

The repo is jj-over-git, so a deployed git hash that 404s on GitHub usually still
resolves to a jj *change*, and jj knows what became of it. To see exactly what
changed (the script only summarises):

```bash
rev=<deployed-sha>
jj log -r "$rev"                       # is it hidden (rewritten)? what change is it?
jj evolog -r "$rev"                    # the rewrite history: which op orphaned it (squash/rebase/…)
jj log -r "<change_id>"                # the change's current, visible commit
jj diff --from "$rev" --to "<change_id>"   # what actually differs between deployed and current
git merge-base --is-ancestor <current-commit> origin/main && echo "content is on main"
```

Interpretation:
- **hidden, current commit is on main** → deployed a pre-rewrite snapshot; content
  landed on main under a new hash. → `just switch <host>`.
- **visible, not on main** → a local commit switched but never pushed; the host
  already runs it. → `jj bookmark set main -r <rev> && jj git push` (no redeploy).
- **git object absent locally** → deployed from a commit this checkout never had.
- **`ahead`** → on an unmerged branch/PR; merge it.

`just switch <host>` changes a live machine — report the diagnosis and recommend the
fix; run it only when the user asks.
