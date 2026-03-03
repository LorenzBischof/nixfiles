# NixOS MicroVM Environment

This workspace runs inside a MicroVM, not directly on the physical host.

Important: if you know the next step, do not ask if you should continue. Always run the tests or validate assumptions without asking. If you have two options, decide or look for more information that would help you decide yourself. It also helps to verify assumptions, so a decision is based on facts.

## Repository Mounts

Primary nixfiles mount:
`/home/microvm/nixfiles`

Some VM profiles also mount a dedicated workspace at:
`/home/microvm/<vmName>`

## Home Manager (MicroVM)

VM-specific writable Home Manager module:
`/home/microvm/nixfiles/hosts/microvms/<vmName>/default.nix`

Switch this VM Home Manager config without a host rebuild:
`home-manager switch --flake .#microvm-<vmName> --override-input nix-secrets ../nix-secrets`

Use `hosts/microvms/<vmName>/default.nix` as a VM-local playground.

Only auto-run the `home-manager switch .#microvm-<vmName>` command without asking when changes are VM-specific (for example files under `hosts/microvms/<vmName>/` or modules imported exclusively by that VM profile).

For shared `nixfiles` configuration (for example under `modules/` or shared `hosts/` config), do not auto-switch from the VM.

## Flake Overrides

For local flake commands in this VM, override `nix-secrets` to the sibling checkout:
`--override-input nix-secrets ../nix-secrets`

## Tooling

If additional tooling is required, use `nix-shell`.

## Host Command Requests

Treat `hostexec` as a last resort.

Always check and reason from `nixfiles` configuration first (for example under
`/home/microvm/nixfiles`, especially `hosts/` and `modules/`) before running
any host command.

Goal: basically never use `hostexec`. Use it only when the required information
or action cannot be obtained from repository files or VM-local commands.

```bash
hostexec -- id
# optional: hostexec --json -- id
```

If `hostexec` is truly required, keep commands minimal and avoid passing secrets
in command arguments.
