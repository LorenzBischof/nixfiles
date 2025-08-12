# CRUSH Configuration for NixOS Configuration Repository

## Build/Test Commands
- **Build current system**: `make switch` or `sudo nixos-rebuild switch --flake .`
- **Test configuration**: `make test` or `sudo nixos-rebuild test --flake .`
- **Deploy to NAS**: `make deploy`
- **Deploy to Oracle**: `make oracle`
- **Dry build NAS**: `make dry-build-nas`
- **Update flake inputs**: `make update` or `nix flake update`
- **Format code**: `nix fmt`
- **Check formatting**: `nix flake check`
- **Enter dev shell**: `nix develop`

## Code Style Guidelines

### Nix Configuration Style
- **Indentation**: 2 spaces, no tabs
- **Imports**: Vertical alignment, relative paths preferred
- **Attribute sets**: Multi-line with proper nesting, trailing semicolons
- **Strings**: Double quotes, use string interpolation `"${var}"` when needed
- **Comments**: Hash comments `#`, include URLs for references
- **Function signatures**: Standard pattern `{ config, pkgs, lib, ... }:`

### Naming Conventions
- **Attributes**: camelCase (`hostName`, `batteryNotifier`)
- **Services**: kebab-case when required (`auto-cpufreq`)
- **Variables**: Descriptive names (`textfileDir`, `syncthing-resolve-conflict`)
- **Files**: kebab-case for modules, descriptive names

### Module Structure
1. Function signature with inputs
2. `let` bindings (if needed)
3. `imports` array
4. Configuration options
5. Services configuration
6. Programs configuration
7. Environment variables

### Error Handling
- Use `lib.mkIf` for conditional configuration
- Validate inputs with `lib.types`
- Include helpful error messages in assertions