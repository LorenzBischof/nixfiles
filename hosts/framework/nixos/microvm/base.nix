{
  inputs,
  vm,
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  guestWorkspace = "/home/microvm/.workspaces/${vm.hostName}";
  roVarNixDb = "/nix/.ro-var-nix-db";
  rwVarNixDb = "/nix/.rw-var-nix-db";
  perVmHomeModulePath = ../../../hosts/microvms + "/${vm.hostName}/default.nix";
  perVmHomeModules = lib.optional (builtins.pathExists perVmHomeModulePath) perVmHomeModulePath;
  hostExecCli = pkgs.writers.writePython3Bin "hostexec" { } ''
    import argparse
    import errno
    import json
    import os
    import socket
    import sys


    def parse_args() -> argparse.Namespace:
        parser = argparse.ArgumentParser(
            prog="hostexec",
            description="Request host command execution over AF_VSOCK.",
        )
        parser.add_argument(
            "--cid",
            type=int,
            default=2,
            help="Host CID (default: 2)",
        )
        parser.add_argument(
            "--port",
            type=int,
            default=int(os.getenv("HOSTEXEC_PORT", "40555")),
            help="Host VSOCK port (default: 40555 or HOSTEXEC_PORT)",
        )
        parser.add_argument(
            "--json",
            action="store_true",
            help="Print raw JSON response",
        )
        parser.add_argument(
            "command",
            nargs=argparse.REMAINDER,
            help="Command to run on host",
        )
        args = parser.parse_args()

        command = list(args.command)
        if command and command[0] == "--":
            command = command[1:]
        if not command:
            parser.error("missing command; use: hostexec -- <command>")
        args.command = command
        return args


    def main() -> int:
        args = parse_args()
        payload = json.dumps({"argv": args.command}).encode("utf-8")

        if not hasattr(socket, "AF_VSOCK"):
            sys.stderr.write("AF_VSOCK is not supported in this environment.\n")
            return 78

        with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as sock:
            try:
                sock.connect((args.cid, args.port))
            except OSError as exc:
                sys.stderr.write(
                    "failed to connect to hostexec bridge at "
                    f"cid={args.cid} port={args.port}: {exc}\n"
                )
                retryable_errnos = {
                    errno.ECONNREFUSED,
                    errno.ECONNRESET,
                    errno.ETIMEDOUT,
                    errno.ENETUNREACH,
                }
                if exc.errno in retryable_errnos:
                    sys.stderr.write(
                        "on the host, check: "
                        "systemctl status microvm-hostexec-vsock.service\n"
                    )
                return 69
            sock.sendall(payload)
            sock.shutdown(socket.SHUT_WR)

            chunks = []
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)

        raw = b"".join(chunks).decode("utf-8", errors="replace")
        if not raw.strip():
            sys.stderr.write(
                "hostexec bridge returned no response; on the host, check: "
                "journalctl -u microvm-hostexec-vsock -n 200 --no-pager\n"
            )
            return 70
        try:
            response = json.loads(raw)
        except json.JSONDecodeError:
            sys.stderr.write(raw)
            return 75

        if args.json:
            sys.stdout.write(json.dumps(response, indent=2, sort_keys=True) + "\n")
        else:
            out = response.get("stdout", "")
            err = response.get("stderr", "")
            if out:
                sys.stdout.write(out)
            if err:
                sys.stderr.write(err)

        return int(response.get("exit_code", 1))


    if __name__ == "__main__":
        raise SystemExit(main())
  '';
in
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    (import ./nix-db-overlay.nix { inherit roVarNixDb rwVarNixDb; })
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = {
    inherit inputs;
    vmName = vm.hostName;
  };
  home-manager.users.microvm = {
    imports = [ ./home.nix ] ++ perVmHomeModules;
  };

  environment.systemPackages = with pkgs; [
    home-manager
    hostExecCli
    jq
    ripgrep
  ];

  networking.hostName = vm.hostName;

  system.stateVersion = "25.11";
  # Virtio block devices can appear late under cloud-hypervisor.
  # Avoid dropping to emergency mode on the default 90s timeout.
  boot.initrd.systemd.settings.Manager.DefaultDeviceTimeoutSec = "3min";

  services.openssh = {
    enable = true;
    startWhenNeeded = true;
    # Keep host keys guest-generated, but avoid RSA generation failures in this VM.
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    authorizedKeysFiles = [ "/etc/ssh/host-keys/ssh_user_root_ed25519.pub" ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "yes";
    };
  };
  # Keep only the VSOCK-activated SSH socket; do not expose the guest over TCP.
  systemd.sockets.sshd.enable = false;

  nix = {
    # Make legacy nix-shell resolve <nixpkgs> from the VM's system nixpkgs.
    nixPath = [ "nixpkgs=${pkgs.path}" ];
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  users.groups.microvm = {
    gid = 1000;
  };
  users.users.microvm = {
    isNormalUser = true;
    group = "microvm";
    uid = 1000;
    shell = pkgs.zsh;
  };

  programs.zsh.enable = true;

  services.resolved.enable = true;
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.tempAddresses = "disabled";
  systemd.network.enable = true;
  systemd.network.networks."10-e" = {
    matchConfig.Name = "e*";
    addresses = [ { Address = "${vm.ipAddress}/24"; } ];
    routes = [ { Gateway = "192.168.83.1"; } ];
  };
  networking.nameservers = [
    "8.8.8.8"
    "1.1.1.1"
  ];

  networking.firewall.enable = false;

  systemd.settings.Manager = {
    DefaultTimeoutStopSec = "5s";
  };

  systemd.mounts = [
    {
      what = "store";
      where = "/nix/store";
      overrideStrategy = "asDropin";
      unitConfig.DefaultDependencies = false;
    }
  ];

  fileSystems = {
    "/nix/.rw-store" = {
      device = "tmpfs";
      fsType = "tmpfs";
      neededForBoot = true;
      options = [
        "mode=0755"
        "size=${toString vm.overlaySizeMiB}M"
      ];
    };
    ${rwVarNixDb} = {
      device = "tmpfs";
      fsType = "tmpfs";
      neededForBoot = true;
      options = [
        "mode=0755"
        "size=200M"
      ];
    };
    ${roVarNixDb} = {
      device = "ro-var-nix-db";
      fsType = "virtiofs";
      options = [ "x-systemd.requires=systemd-modules-load.service" ];
      neededForBoot = true;
      noCheck = true;
    };
    "/nix/var/nix/db" = {
      device = "overlay";
      fsType = "overlay";
      neededForBoot = true;
      options = [
        "lowerdir=${roVarNixDb}"
        "upperdir=${rwVarNixDb}/var/nix/db"
        "workdir=${rwVarNixDb}/work"
      ];
      depends = [
        "/nix/.ro-store"
        "/nix/.rw-store"
        roVarNixDb
        rwVarNixDb
      ];
    };
  };

  microvm = lib.mkMerge [
    {
      vsock.ssh.enable = true;
      writableStoreOverlay = "/nix/.rw-store";

      volumes = [
        {
          mountPoint = "/var";
          image = "var.img";
          size = 8192;
        }
      ];

      shares = [
        {
          proto = "virtiofs";
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "ro-var-nix-db";
          source = "/nix/var/nix/db";
          mountPoint = roVarNixDb;
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "ssh-authorized-keys";
          source = vm.hostSshKeyDir;
          mountPoint = "/etc/ssh/host-keys";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "workspace";
          source = vm.workspace;
          mountPoint = guestWorkspace;
        }
        {
          proto = "virtiofs";
          tag = "host-codex";
          source = "/home/lbischof/.codex";
          mountPoint = "/run/host-credentials/codex";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "host-github-token";
          source = "/run/host-github-token";
          mountPoint = "/run/host-credentials/github-token";
          readOnly = true;
        }
        {
          proto = "virtiofs";
          tag = "host-claude";
          source = "/var/lib/microvm-claude";
          mountPoint = "/run/host-credentials/claude";
        }
      ];

      interfaces = [
        {
          type = "tap";
          id = vm.tapId;
          mac = vm.mac;
        }
      ];

      hypervisor = lib.mkDefault "cloud-hypervisor";
      # Workaround for microvm.nix#366: cloud-hypervisor's default --serial tty
      # severely slows systemd-journald during boot (up to 60s delay).
      # Use virtio-console instead.
      cloud-hypervisor.extraArgs = [
        "--serial" "off"
        "--console" "tty"
      ];
      vcpu = lib.mkDefault 8;
      mem = lib.mkDefault 16384;
      socket = "control.socket";
    }
    (lib.optionalAttrs (vm ? vsockCid && vm.vsockCid != null) { vsock.cid = vm.vsockCid; })
  ];
}
