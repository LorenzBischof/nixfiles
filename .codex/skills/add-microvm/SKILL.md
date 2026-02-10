---
name: add-microvm
description: Use when you need to add a new MicroVM definition in this nixfiles repo.
---

# Add A MicroVM (nixfiles)

## Overview
MicroVMs are defined on the framework host in `hosts/framework/nixos/microvms/profiles.nix` and get a per-VM Home Manager module from `hosts/microvms/<name>/default.nix`.

Key wiring:
- `hosts/framework/nixos/microvm.nix` loads profiles from `hosts/framework/nixos/microvms/profiles.nix`.
- `hosts/framework/nixos/microvm-base.nix` imports `hosts/microvms/<name>/default.nix` into the VM Home Manager config.
- `flake.nix` uses `profiles.nix` to build `microvmHomeConfigurations`.

## Steps
1. Create the per-VM Home Manager file (required, even if empty):
   - `hosts/microvms/<name>/default.nix`

2. Register the MicroVM profile in `hosts/framework/nixos/microvms/profiles.nix`:
   - Add a new `<name> = { ... };` entry with at least `ipAddress`, `tapId`, and `mac`.
   - Keep `ipAddress`, `tapId`, and `mac` unique. The network is `192.168.83.0/24` with gateway `192.168.83.1`.
   - Optional fields include:
     - `workspace`, `relativeMounts`, `overlaySizeMiB`, `autostart`, `extraZshInit`
     - `extraModules = [ ./<name>.nix ];` (only if you need custom NixOS config)

3. (Optional) Add VM-specific system config:
   - Create `hosts/framework/nixos/microvms/<name>.nix`
   - Reference it via `extraModules = [ ./<name>.nix ];`

4. Rebuild on the framework host:
   - `just switch`

5. Start and access the VM:
   - `microvm-here` from a repo whose root name matches `<name>` (auto-derives the VM name), or
   - `sudo systemctl start microvm@<name>` and then `ssh microvm-<name>`.

## Notes
- `relativeMounts` mounts extra paths (relative to the workspace) into the same relative locations inside the VM.
- `microvm-here` creates/updates `/var/lib/microvm-workspaces/<name>` to point at the current repo and waits for SSH.
- VM Home Manager config can be switched inside the VM with:
  `nix run github:nix-community/home-manager -- switch --flake .#microvm-<name>`
