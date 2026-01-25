# NixOS Environment

This system is running NixOS, a declarative Linux distribution.

## NixOS Configuration Repository

The NixOS system configuration is managed in: `~/git/github.com/lorenzbischof/nixfiles`

To update this global CLAUDE.md file or skills in `~/.claude/skills/`, edit the source files in `modules/home/ai/` in the repository and run `just switch` to apply changes.

## Important: System Changes Require Rebuilds

NixOS is declarative - system configuration changes require rebuilding the system with `just switch` or `sudo nixos-rebuild switch --flake .#hostname`.
Changes are not applied immediately like in traditional Linux distributions.

## Installing Additional Tools

If you need additional tools or packages that are not currently available, you can use `nix-shell`:

```bash
# Install a package temporarily in a new shell
nix-shell -p packageName

# Install multiple packages
nix-shell -p jq python3 nodejs
```

You can search for packages at https://search.nixos.org/packages

For permanent installation, packages should be added to the NixOS configuration repository.
