# NixOS MicroVM Environment

This workspace runs inside a MicroVM, not directly on the physical host.

Important: if you know the next step, do not ask if you should continue. Always run the tests or validate assumptions without asking. If you have two options, decide or look for more information that would help you decide yourself. It also helps to verify assumptions, so a decision is based on facts.

## Repository Mounts

Primary nixfiles mount:
`/home/microvm/nixfiles`

Some VM profiles also mount a dedicated workspace at:
`/home/microvm/<vmName>`

## Home Manager (MicroVM)

VM-specific writable Home Manager directory (entrypoint is `default.nix`):
`/home/microvm/nixfiles/hosts/microvms/<vmName>/`

Switch this VM Home Manager config without a host rebuild:
`home-manager switch --flake .#microvm-<vmName> --override-input nix-secrets ../nix-secrets`

You are allowed to use this directory as a playground and should always switch without asking.

## Flake Overrides

For local flake commands in this VM, override `nix-secrets` to the sibling checkout:
`--override-input nix-secrets ../nix-secrets`

## Tooling

If additional tooling is required, use `nix-shell`.
