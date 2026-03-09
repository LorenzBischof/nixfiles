# MicroVM Workspace Shares

This doc keeps only operator-relevant behavior that is easy to miss in code.

## What `microvm-here` manages

- Always creates `/var/lib/microvm-workspaces`.
- Ensures `/var/lib/microvm-workspaces/<vmName>` is a directory.
- Creates a per-repo bind mount directly under that directory:
  - `/var/lib/microvm-workspaces/<vmName>/<cwdName>-<repoHash>`
  - bind-mounted to the current repo root.
- For VM profile `nixfiles`, `nix-secrets` at
  `/var/lib/microvm-workspaces/nixfiles/nix-secrets` becomes a bind mount of
  sibling `../nix-secrets` when present.
- For VM profile `nixfiles`, when sibling `../nix-secrets` is missing,
  `/var/lib/microvm-workspaces/nixfiles/nix-secrets` is ensured as a plain directory.
- In the `nixfiles` VM profile, that workspace path is visible in the guest at
  `/home/microvm/.workspaces/nixfiles/nix-secrets`.

## Runtime caveat

If a VM started before workspace `nix-secrets` sources were rebound, it can keep seeing
stale content from the previous source. Restart that VM.

## Operator guidance

- Start VMs from the repo you want mounted as the profile workspace.
- If you rebind a workspace source by starting from another repo later, restart already-running VMs.
- Concurrent repos targeting the same VM profile are supported via distinct per-repo bind
  mount paths under `/var/lib/microvm-workspaces/<vmName>/`.
- Per-repo workspace bind mounts are cleaned up when `microvm@<vmName>` stops (not when
  `microvm-here` exits).
- If cleanup cannot unmount a stale workspace mount, a warning is logged in the
  `microvm@<vmName>` journal.

## Source of truth

- Host launcher logic:
  `hosts/framework/nixos/microvm/module.nix` (`microvm-here`)
- Guest share mounts:
  `hosts/framework/nixos/microvm/base.nix`
- Regression test for bind-mount lifecycle:
  `tests/microvm.nix`
