# NixOS Environment

This system is running NixOS, a declarative Linux distribution.

## NixOS Configuration Repository

The NixOS system configuration is managed in: `~/git/github.com/lorenzbischof/nixfiles`

To update the host/global AGENTS.md file for Codex, edit the source file in `modules/home/ai/AGENTS.md` in the repository and run `just switch` to apply changes.

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

Run these with the sandbox disabled. Anything that talks to the nix daemon —
`nix-shell`, `nix build`, `nix eval` — fails inside the sandbox with `cannot
create Unix domain socket: Operation not permitted`, which reads like a nix
error rather than a permission one.

You can search for packages at https://search.nixos.org/packages

For permanent installation, packages should be added to the NixOS configuration repository.

## The agent sandbox

The Bash tool runs inside a bwrap sandbox that hides the real machine. Host
device introspection is not just restricted but *misleading*: `lspci` returns
nothing, `/dev/accel` and `/sys/class/accel` are absent, and `dmesg` is empty,
even when the hardware is present and its module loaded. Never conclude
hardware is missing from inside the session — inspect the nix config, or have
the user run the check.

The sandbox also drops 0-byte deny stubs into the working directory for every
path on its deny list (`.bashrc`, `.gitconfig`, `.claude/settings.json`, …),
which is why version-control commands belong outside it.

## sudo needs a password

`sudo` has no passwordless rule and the agent shell has no tty, so anything
needing root — `strace -p`, `conntrack -E`, `systemctl restart` — cannot run
from the Bash tool at all, sandbox or not. Hand the user the exact command to
run with the `! <command>` prompt prefix instead.

Never put `2>/dev/null` on a `sudo` invocation. It turns the failure into empty
output, which reads exactly like a real negative result; that once produced a
confident wrong diagnosis ("the network is silent") from a `conntrack` that had
never started.

## Revisiting decisions

Treat past decisions as conclusions based on the evidence available then. When
new information challenges their assumptions or reveals an alternative they did
not consider, reassess the decision and update its record with the new evidence
and outcome.

## Basic Memory

Follow upstream Basic Memory guidance and keep all upstream skills available.

Before proposing an experiment or deciding between variants, search the graph
for the topic and follow the Relations of the task the session is actually
working on; the active-task list spans projects, so an unrelated task's links
are noise. Read a note's provenance markers rather than its tone — observations
separate what was measured from what is unverified or open, and a measured fact
holds only for the versions the note records; against anything newer it is a
hypothesis.
