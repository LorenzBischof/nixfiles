# AGENTS.md

A personal NixOS configuration using flakes, managing several hosts with shared
modules for both system and home-manager config.

## Version control

This repository uses jj (Jujutsu) with a colocated git repo; jj owns the working
copy. Use jj for status, diffs, history, commits and publishing — not `git
status`, `git diff`, `git add`, `git commit` or `git stash`. The `jujutsu` skill
holds the workflow: work in an empty `@`, `jj absorb`, splitting one change into
several, and the reach of `jj undo`.

Run jj with the sandbox disabled — a sandboxed jj writes 0-byte deny stubs into
the repository root, and they get snapshotted into the change.

## Layout and module pattern

`hosts/<host>/` holds per-host config, split into `nixos/` and `home/`.
`modules/nixos/` and `modules/home/` hold what is shared across hosts, and
`packages/` the custom packages.

Modules define options under a `my.*` namespace and host configs enable them:
`my.system.*`, `my.services.*`, `my.programs.*`, `my.profiles.*` — for example
`my.system.autoUpgrade`, `my.programs.firefox`, `my.profiles.ai`.

## Secrets

The `secrets.*` values the host configs read come from the private `nix-secrets`
flake, whose `default.nix` holds them in plaintext — OIDC client secrets, the
restic repository, domains, ntfy and healthchecks IDs. Never read that file or
print an evaluated `secrets.*` value: not into a transcript, a CI log, or a PR
comment. This repo and its Actions logs are public.

## Nix + Bash interpolation

When writing shell scripts inside Nix strings (for example `writeShellScript` or
`writeShellApplication`), Nix interpolates `${...}` before Bash sees the script.

- Use `''${var}` when you need a literal Bash `${var}` expansion at runtime.
- `pkgs.writers.writePython3Bin` here is `name attrs text` (use `{ }` for
  `attrs` when unused).

## ntfy notification lifecycle

When sending ntfy notifications from recurring checks/services, keep one
updatable notification per host/service rather than a new message each run — see
https://docs.ntfy.sh/publish/#updating-deleting-notifications

- Publish to a stable ID: `https://ntfy.sh/<topic>/<sequence-id>`, where
  `<sequence-id>` derives from hostname + check name. Updates go to that same URL.
- Clear a resolved state with `PUT https://ntfy.sh/<topic>/<sequence-id>/clear`.

## SSH access to hosts

Run SSH with the sandbox disabled. Open one `ControlMaster` per session and reuse
it for all further commands to that host:

```bash
ssh -F none -MNf -o ControlPath=~/.ssh/controlmasters/<name> -o ControlPersist=4h \
  -o IdentityFile=~/.ssh/id_ed25519_sk_rk_homelab -o IdentitiesOnly=yes nas 'echo ok'  # once
ssh -F none -o ControlPath=~/.ssh/controlmasters/<name> nas '<command>'                # reuse
```

For debugging the home router (login, useful OIDs, known bugs), see
`docs/router-debugging.md`.

## Commands

```bash
just switch            # activate for this host; `just switch nas` for a remote one
just test              # same, without persisting
nix flake check        # evaluate every host and package
nix build .#nixosConfigurations.<host>.config.system.build.toplevel   # build only
home-manager switch --flake .#bischoflo                               # WSL, standalone
```

## Validating runtime behaviour

When a task is about runtime behaviour of the `framework` desktop session — Sway
and XWayland, window matching, keybindings, GUI app launch and Electron Wayland
mode, or anything that only appears after login — a successful build and static
inspection are preliminary. Verify it in the agent VM before closing the task
(the `nixos-agent-test-vm` skill covers that), and if you can't, say exactly what
blocked it and what you verified instead.
