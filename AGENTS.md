# AGENTS.md

This is a personal NixOS configuration repository using Nix Flakes. It manages multiple systems with shared modules for both NixOS system configuration and home-manager user configuration.

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

## Development Guidelines

- **Prefer options over packages** - use built-in configuration options rather than installing packages directly
- **Keep related configuration in separate files**

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

## NixOS Documentation

Configuration options:
- `man configuration.nix` - System-level NixOS options
- `man home-configuration.nix` - Home-manager options

Manual source files (markdown, organized by topic):

### Nixpkgs Manual
https://github.com/NixOS/nixpkgs/tree/master/doc
- languages-frameworks/: 50+ languages (python, rust, go, haskell, javascript, java, etc.)
- build-helpers/: fetchers, testers, trivial-builders, dev-shell-tools, images
- hooks/: 40+ build hooks (cmake, meson, python, perl, autopatchelf, etc.)
- stdenv/: standard environment, cross-compilation, meta, multiple-output, passthru
- functions/: Nix library functions reference
- module-system/: NixOS module system documentation
- packages/: package management
- contributing/: contribution guidelines
- toolchains/: LLVM and cross-compilation toolchains

### Nix Manual
https://github.com/NixOS/nix/tree/master/doc/manual/source
- language/: syntax, types, operators, derivations, builtins, string-interpolation
- command-ref/: nix-build, nix-shell, nix-env, nix-store, experimental-commands
- package-management/: package handling
- advanced-topics/: distributed-builds, diff-hook, post-build-hook, eval-profiler
- architecture/: system design
- protocols/: protocol specifications
- store/: store implementation

### NixOS Manual
https://github.com/NixOS/nixpkgs/tree/master/nixos/doc/manual
- configuration/: config-syntax, package-mgmt, file-systems, networking, user-mgmt, firewall, gpu-accel, linux-kernel, wayland, x-windows, ssh, wireless
- administration/: system administration
- installation/: installation procedures
- development/: development guides

### NixOS Wiki
Note: There are two NixOS wikis. Prefer the official one.
- https://wiki.nixos.org/ (Official NixOS wiki - preferred)
- https://nixos.wiki/ (Community wiki)
