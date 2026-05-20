# Setting up the VM harness for a new host

Read this only if `nix run .#<host>-agent-vm` doesn't already exist for the NixOS config you want to test. Otherwise stick with `SKILL.md`.

The harness is provided by the [`nixos-agent-test-vm`](https://github.com/lorenzbischof/nixos-agent-test-vm) flake, which exposes a single top-level function: `mkAgentVm`. Internally it wraps `pkgs.testers.runNixOSTest` and bakes in the agent driver (a Python REPL bound to a Unix socket under `$XDG_RUNTIME_DIR`). Per-host wiring is one `apps.<system>.<host>-agent-vm = nixos-agent-test-vm.mkAgentVm { ... }` attribute in the consuming flake.

## 1. Add the flake input

```nix
{
  inputs.nixos-agent-test-vm.url = "github:lorenzbischof/nixos-agent-test-vm";
}
```

No `inputs.nixpkgs.follows` is needed — the helper takes `pkgs` as an argument, so it picks up the consumer's nixpkgs automatically.

## 2. Define an app per host

```nix
outputs = { self, nixpkgs, nixos-agent-test-vm, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    apps.${system}.<host>-agent-vm = nixos-agent-test-vm.mkAgentVm {
      inherit pkgs;
      host = "<host>";
      nixosConfig = self.nixosConfigurations.<host>;

      # Optional NixOS module of host-specific VM overrides. Drop any line
      # whose option isn't actually defined by the host — mkForce against a
      # missing option errors at eval time.
      extraConfig = { lib, pkgs, ... }: {
        boot.lanzaboote.enable = lib.mkForce false;
        services.tailscale.enable = lib.mkForce false;
        services.syncthing.enable = lib.mkForce false;
        virtualisation.docker.enable = lib.mkForce false;
        virtualisation.libvirtd.enable = lib.mkForce false;

        # If the host has a graphical session you want to drive, override the
        # display manager to auto-login a known user. Example for greetd+Sway:
        # services.greetd.settings.initial_session = {
        #   command = "${pkgs.bash}/bin/bash -lc 'export WLR_RENDERER_ALLOW_SOFTWARE=1; exec ${pkgs.sway}/bin/sway'";
        #   user = "<username>";
        # };
      };
    };
  };
```

The helper already bakes in the universals: `console.keyMap = "us"`, 4 GiB / 4 cores, virtio-gpu, and the agent driver script.

## What the function does

`mkAgentVm` takes the existing `nixosConfiguration` and re-evaluates it as a `runNixOSTest` node, preserving the host's `specialArgs` and full module list. It layers a `virtualisation { ... }` block on top and uses the bundled `agent-vm-driver.py` as the `testScript`. The driver opens a Unix socket at `$XDG_RUNTIME_DIR/<host>-agent-vm.sock` and accepts one Python line per request, replying with one JSON line per response.

The returned attribute is a standard flake `apps.<system>.<name>` value: `{ type = "app"; program = "${vm.driver}/bin/nixos-test-driver"; }`.

## Verifying

```bash
nix run .#<host>-agent-vm -L > /tmp/vm-log 2>&1 &
while ! test -S "$XDG_RUNTIME_DIR/<host>-agent-vm.sock" 2>/dev/null; do sleep 1; done
echo 'machine.wait_for_unit("default.target")' \
  | socat -t 240 - UNIX-CONNECT:$XDG_RUNTIME_DIR/<host>-agent-vm.sock
```

If the launch dies fast, rerun in the foreground (`nix run .#<host>-agent-vm -L`) to see the build/boot error.
