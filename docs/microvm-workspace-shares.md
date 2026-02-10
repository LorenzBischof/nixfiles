# MicroVM Workspace Share Behavior

This note documents how `microvm-here` and MicroVM virtiofs shares interact.

## Problem Shape

MicroVMs use host paths under `/var/lib/microvm-workspaces/*` as virtiofs `source` paths.
If a `source` path is missing, the VM share mount can fail.

For this repo, important shared paths are:

- `/var/lib/microvm-workspaces/nixfiles`
- `/var/lib/microvm-workspaces/nix-secrets`
- `/var/lib/microvm-workspaces/nixfiles/hosts/microvms/<vmHostName>`

## Current Behavior

`microvm-here` in `hosts/framework/nixos/microvm.nix` manages these paths:

- Always ensures `/var/lib/microvm-workspaces` exists.
- Always ensures a read-only placeholder for `/var/lib/microvm-workspaces/nix-secrets` if missing.
- When starting VM `nixfiles`:
  - Replaces `/var/lib/microvm-workspaces/nixfiles` with a symlink to the current repo root.
  - If sibling `../nix-secrets` exists, replaces `/var/lib/microvm-workspaces/nix-secrets` with a symlink to it.
  - Otherwise keeps/creates a read-only placeholder directory for `nix-secrets`.
- When starting any non-`nixfiles` VM:
  - Ensures a read-only placeholder exists for `/var/lib/microvm-workspaces/nixfiles`.
- Ensures `/var/lib/microvm-workspaces/nixfiles/hosts/microvms/<vmHostName>` exists:
  - If `nixfiles` is a symlink, create the directory in the real nixfiles repo.
  - If `nixfiles` is a placeholder directory, create it as read-only placeholder content.

Read-only placeholders are `root:root` with mode `0555` to avoid accidental writes by normal VM users.

## Important Runtime Constraint

Changing host share sources (placeholder directory -> symlink) after a VM is already running does not reliably refresh the guest view.
In practice, running VMs can continue to see old placeholder content until restart.

Implication:

- If a VM started before `nixfiles`/`nix-secrets` symlinks were established, restart that VM to get the updated share source.

Guest remount or restarting only `virtiofsd` is not treated as a reliable fix in this setup.

## Operational Guidance

- Start `nixfiles` early if other VMs depend on live nixfiles/nix-secrets content.
- If you had to start another VM first, restart that VM after `nixfiles` establishes symlinks.
- Avoid writing into placeholder-backed paths; those are compatibility fallbacks, not canonical storage.
