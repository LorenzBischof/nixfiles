# Syncing the `test-nixos-vm` skill from the external flake

## Context

The `test-nixos-vm` skill (`SKILL.md` + `SETUP.md`) lives in the external
[`nixos-agent-test-vm`](https://github.com/lorenzbischof/nixos-agent-test-vm)
repo, alongside the `mkAgentVm` flake output that this repo already consumes.

Coding agents discover skills from `<repo>/.claude/skills/` (and
`.agents/skills/` for Codex), so the skill needs to be present in this repo's
working tree — not just under `~/.claude/skills/` (which is where
`home.file` would deploy it).

We want one source of truth (the external repo) and a low-friction way to
pull the current version into this tree.

## Approach

Add an `install` app to the external flake. Running it copies
`skills/test-nixos-vm/` from the flake source into `$PWD/.claude/skills/`
(and `.agents/skills/` if present), so any project can install or refresh
the skill with a single command.

```sh
# From within this repo (uses the pinned flake.lock revision):
nix run .#nixos-agent-test-vm.install

# Or standalone, from anywhere (latest from GitHub):
nix run github:lorenzbischof/nixos-agent-test-vm#install
```

The copied files are committed to the project — agents read them from the
working tree, and diffs are reviewable when the skill updates.

## Update workflow

1. `nix flake update nixos-agent-test-vm` — bump the pinned revision.
2. `nix run .#nixos-agent-test-vm.install` — refresh the working copy.
3. Commit the resulting changes under `.claude/skills/test-nixos-vm/` (and
   `.agents/skills/test-nixos-vm/` if used).

The `--refresh` flag on the standalone form fetches the latest GitHub HEAD
without touching `flake.lock`, useful for ad-hoc updates outside this repo.

## Implementation sketch (external flake)

```nix
apps.${system}.install = {
  type = "app";
  program = toString (pkgs.writeShellScript "install-test-nixos-vm-skill" ''
    set -euo pipefail
    src=${self}/skills/test-nixos-vm
    for target in .claude/skills .agents/skills; do
      if [ -d "$(dirname "$target")" ] || [ "$target" = ".claude/skills" ]; then
        mkdir -p "$target"
        cp -rL --no-preserve=mode,ownership "$src" "$target/"
        echo "installed $target/test-nixos-vm"
      fi
    done
  '');
};
```

(Sketch — real impl needs to handle `$PWD` explicitly via the wrapper that
`nix run` provides, and decide whether to always create `.agents/skills`
or only refresh it if already present.)

## Why not the alternatives

- **Vendoring via `home.file`** — deploys to `~/.claude/skills/`, which is
  user-global. The skill is project-specific (it talks to this repo's
  `framework-agent-vm`), so it belongs in the project tree.
- **Git submodule** — works, but decouples the skill version from
  `flake.lock`, which already pins the same external repo for `mkAgentVm`.
  Two pinning mechanisms for one dependency.
- **`just sync-skills` recipe** — viable, but adds a repo-specific entry
  point for something that other projects (consuming the same flake) would
  also benefit from. An app on the flake itself is reusable.
