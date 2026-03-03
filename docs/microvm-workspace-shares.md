# MicroVM Workspace Shares

This doc keeps only operator-relevant behavior that is easy to miss in code.

## What `microvm-here` manages

- Always creates `/var/lib/microvm-workspaces`.
- Always maintains `/var/lib/microvm-workspaces/<vmName>` as a symlink to the current repo root.
- Maintains shared roots used by VM virtiofs mounts:
  - `/var/lib/microvm-workspaces/nixfiles`
  - `/var/lib/microvm-workspaces/nix-secrets`
- For VM `nixfiles`:
  - `nixfiles` becomes a symlink to the current repo root.
  - `nix-secrets` becomes a symlink to sibling `../nix-secrets` when present.
  - Otherwise `nix-secrets` is a read-only placeholder directory.
- For non-`nixfiles` VMs:
  - `nixfiles` is ensured to exist as a read-only placeholder when no symlink exists yet.
- Ensures `nixfiles/hosts/microvms/<vmHostName>` exists for all known VM host names.
- For each configured `relativeMounts` entry, creates a managed path under
  `/var/lib/microvm-workspaces/<vmName>/<relative-path>`:
  - symlink to source path when source exists
  - plain directory placeholder when source is missing

Read-only placeholders are created as `root:root` mode `0555`.

## Runtime caveat

If a VM started while `nixfiles`/`nix-secrets` were placeholders, and later those host paths
switch to symlinks, the running VM can keep seeing stale placeholder content. Restart that VM.

## Operator guidance

- Start `nixfiles` early when other VMs depend on live `nixfiles` or `nix-secrets` content.
- If you started another VM first, restart it after `nixfiles` establishes symlinks.

## Source of truth

- Host launcher logic:
  `hosts/framework/nixos/microvm/module.nix` (`microvm-here`)
- Guest share mounts:
  `hosts/framework/nixos/microvm/base.nix`
- Regression test for placeholder/symlink lifecycle:
  `tests/microvm.nix`
