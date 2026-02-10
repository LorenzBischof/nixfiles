# AGENTS.md

This is a personal NixOS configuration repository using Nix Flakes. It manages multiple systems with shared modules for both NixOS system configuration and home-manager user configuration.

## AGENTS.md Layers

There are two relevant AGENTS.md sources in this repo setup:

- **Project-local AGENTS.md (this file)**: `AGENTS.md`
  - Repository-specific guidance for working in `nixfiles`.
- **Global AGENTS.md sources**:
  - Host/default: `modules/home/ai/AGENTS.md`
  - MicroVM guest: `hosts/framework/nixos/AGENTS.microvm.md`

## Repository Architecture

### Directory Layout

- **`hosts/`**: Per-host configurations
  - Each host has a subdirectory (e.g., `framework/`, `nas/`, `vps/`, `wsl/`)
  - Within each host: `nixos/` contains system config, `home/` contains home-manager config
  - Host-specific files and specialized modules

- **`modules/`**: Reusable modules shared across systems
  - `modules/nixos/`: System-level modules imported into all NixOS hosts
    - Common settings, autoupgrade, nginx config, monitoring
    - Custom services: `detect-reboot-required`, `detect-syncthing-conflicts`, `nixpkgs-age-monitor`
  - `modules/home/`: User-level modules for home-manager
    - `wayland/`: Sway window manager, waybar, foot terminal, keybindings
    - `shell/`: Shell configuration
    - `git/`: Git configuration
    - `ai/`: AI tools configuration
    - `firefox.nix`: Firefox customizations

- **`tests/`**: NixOS VM tests using `pkgs.testers.runNixOSTest`

- **`packages/`**: Custom package definitions

### Module Pattern

This repository uses a custom options pattern with `my.*` namespace:
- System options: `my.system.*` (e.g., `my.system.autoUpgrade`)
- Service options: `my.services.*` (e.g., `my.services.detect-reboot-required`)
- Program options: `my.programs.*` (e.g., `my.programs.firefox`, `my.programs.git`)
- Profile options: `my.profiles.*` (e.g., `my.profiles.ai`)

Modules define options and are imported into host configurations, which then enable/configure them.

## Nix + Bash Interpolation Note

When writing shell scripts inside Nix strings (for example `writeShellScript` or `writeShellApplication`), Nix interpolates `${...}` before Bash sees the script.

- Use `''${var}` when you need a literal Bash `${var}` expansion at runtime.

## Common Development Commands

### Building and Switching

```bash
# Activate configuration for current host (framework)
just switch

# Activate configuration for remote host
just switch nas
just switch vps

# Test configuration without persisting
just test
just test nas
just test vps
```

### Building Manually

```bash
# Build and activate configuration for current host
sudo nixos-rebuild switch --flake .#framework

# Build without activating (test first)
sudo nixos-rebuild build --flake .#framework

# Build for specific host without switching
nix build .#nixosConfigurations.nas.config.system.build.toplevel

# Update home-manager for WSL (standalone)
home-manager switch --flake .#bischoflo
```

### Testing

```bash
# Run all NixOS tests
nix flake check

# Run specific test
nix build .#checks.x86_64-linux.attic --print-build-logs
```

## Focused Docs

- MicroVM workspace/symlink/share behavior: `docs/microvm-workspace-shares.md`
