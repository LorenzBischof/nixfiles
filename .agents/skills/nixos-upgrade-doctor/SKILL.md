---
name: nixos-upgrade-doctor
description: Use when a host's NixOS auto-upgrade (nixos-upgrade.service) is stuck, skipped, or not applying — especially when the guard reports the deployed commit is missing on GitHub. Points at the diagnosis script and shows how to dig into what actually changed.
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

## When the output is unclear

A deployed hash that 404s on GitHub was usually rewritten (amend, rebase, squash
merge) after it was switched. To see exactly what changed (the script only
summarises):

```bash
rev=<deployed-sha>
git diff "$rev" origin/main          # what differs between deployed and main
git branch -r --contains "$rev"      # which pushed branch it lives on, if any
```

`just switch <host>` changes a live machine — report the diagnosis and recommend the
fix; run it only when the user asks.
