---
name: nix-docs
description: Use when you need to lookup documentation for NixOS configuration, Nix packaging, Nix functions or anything else related to Nix.
---

# NixOS Documentation

## Development Best Practices

- **Prefer options over packages** - use built-in configuration options rather than installing packages directly
- **Keep related configuration in separate files**

## Configuration Options
- `man configuration.nix` - System-level NixOS options
- `man home-configuration.nix` - Home-manager options

Manual source files (markdown, organized by topic):

## Nixpkgs Manual
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

## Nix Manual
https://github.com/NixOS/nix/tree/master/doc/manual/source
- language/: syntax, types, operators, derivations, builtins, string-interpolation
- command-ref/: nix-build, nix-shell, nix-env, nix-store, experimental-commands
- package-management/: package handling
- advanced-topics/: distributed-builds, diff-hook, post-build-hook, eval-profiler
- architecture/: system design
- protocols/: protocol specifications
- store/: store implementation

## NixOS Manual
https://github.com/NixOS/nixpkgs/tree/master/nixos/doc/manual
- configuration/: config-syntax, package-mgmt, file-systems, networking, user-mgmt, firewall, gpu-accel, linux-kernel, wayland, x-windows, ssh, wireless
- administration/: system administration
- installation/: installation procedures
- development/: development guides

## NixOS Wiki
Note: There are two NixOS wikis. Prefer the official one.
- https://wiki.nixos.org/ (Official NixOS wiki - preferred)
- https://nixos.wiki/ (Community wiki)
