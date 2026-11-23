---
name: nixos-upgrade-doctor
description: Use when a host's NixOS auto-upgrade (nixos-upgrade.service) is stuck, skipped, or not applying — especially when the guard reports the deployed commit is missing on GitHub. Points at the diagnosis script and shows how to dig into what actually changed with git.
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

## When the output is unclear: dig with git

A deployed hash that 404s on GitHub usually means the commit was rewritten (amend,
rebase, squash merge) after it was switched, or never pushed. To see exactly what
changed (the script only summarises):

```bash
rev=<deployed-sha>
git log -1 "$rev"                                   # is it known locally? what was it?
git log origin/main --format='%h %T %s' | grep "$(git rev-parse "$rev^{tree}")"  # same content on main?
git diff "$rev" origin/main                         # what differs between deployed and main
git branch -a --contains "$rev"                     # which branch it lives on, if any
```

Interpretation:
- **same tree on main** → content landed on main under a new hash. → `just switch <host>`.
- **on a branch, not on main** (`ahead`) → an unmerged branch/PR; merge it (no redeploy).
- **on no branch** → a local commit switched but never pushed; push and merge it.
- **git object absent locally** → deployed from a commit this checkout never had.

`just switch <host>` changes a live machine — report the diagnosis and recommend the
fix; run it only when the user asks.
