{ inputs, ... }:
{

  nodes = {
    host = { pkgs, ... }:
      {
        _module.args = {
          inherit inputs;
        };

        imports = [
          inputs.microvm.nixosModules.host
          inputs.home-manager.nixosModules.home-manager
          ../hosts/framework/nixos/microvm.nix
        ];

        virtualisation.memorySize = 6144;
        virtualisation.cores = 4;

        my.microvms = {
          testvm = {
            ipAddress = "192.168.83.10";
            tapId = "microvm9";
            mac = "02:00:00:00:00:09";
            extraModules = [
              ({ lib, ... }: {
                microvm.hypervisor = lib.mkForce "qemu";
                microvm.vcpu = 2;
                microvm.mem = 3072;
                microvm.vsock.cid = 7;
              })
            ];
          };
          nixfiles = {
            ipAddress = "192.168.83.12";
            tapId = "microvm8";
            mac = "02:00:00:00:00:08";
            extraModules = [
              ({ lib, ... }: {
                microvm.hypervisor = lib.mkForce "qemu";
                microvm.vcpu = 2;
                microvm.mem = 3072;
                microvm.vsock.cid = 8;
              })
            ];
          };
        };

        users.users.lbischof = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          home = "/home/lbischof";
        };

        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          users.lbischof = {
            home.stateVersion = "25.11";
            home.username = "lbischof";
            home.homeDirectory = "/home/lbischof";
            programs.ssh = {
              enable = true;
              enableDefaultConfig = false;
            };
          };
        };

        security.sudo = {
          enable = true;
          wheelNeedsPassword = false;
        };

        environment.systemPackages = with pkgs; [
          netcat-openbsd
          git
          qemu_kvm
        ];

        networking.hostName = "test-host";
        system.stateVersion = "25.11";

        networking.useDHCP = false;
        systemd.network.enable = true;
        systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig.DHCP = "yes";
        };
        systemd.network.netdevs."20-microbr".netdevConfig = {
          Kind = "bridge";
          Name = "microbr";
        };
        systemd.network.networks."20-microbr" = {
          matchConfig.Name = "microbr";
          addresses = [ { Address = "192.168.83.1/24"; } ];
          networkConfig.ConfigureWithoutCarrier = true;
        };
        systemd.network.networks."21-microvm-tap" = {
          matchConfig.Name = "microvm*";
          networkConfig.Bridge = "microbr";
        };
        networking.nat = {
          enable = true;
          internalInterfaces = [ "microbr" ];
          externalInterface = "eth0";
        };
      };
  };

  testScript = # python
    ''
      start_all()
      host = machines[0]

      host.succeed("install -d -m 0755 /home/lbischof/testvm")
      host.succeed("install -d -m 0755 /home/lbischof/nix-secrets")
      host.succeed("install -d -m 0700 /home/lbischof/.ssh")
      host.succeed("install -d -m 0755 /home/lbischof/.codex")
      host.succeed("printf 'hello' > /home/lbischof/testvm/marker.txt")
      host.succeed("chown -R lbischof:users /home/lbischof")

      # Start a non-nixfiles VM first. At this point nixfiles share is a readonly placeholder.
      host.succeed("su - lbischof -c 'cd /home/lbischof/testvm && microvm-here -- true'")
      host.succeed("test -d /var/lib/microvm-workspaces/nixfiles")
      host.fail("test -L /var/lib/microvm-workspaces/nixfiles")

      host.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/testvm/id_ed25519 "
        "microvm@192.168.83.10 'test -f /home/microvm/testvm/marker.txt'"
      )
      host.fail(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/testvm/id_ed25519 "
        "microvm@192.168.83.10 'touch /home/microvm/nixfiles/hosts/microvms/testvm/.write-before-restart-should-fail'"
      )
      host.fail(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/testvm/id_ed25519 "
        "microvm@192.168.83.10 'touch /home/microvm/nixfiles/.write-should-fail'"
      )
      host.fail(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/testvm/id_ed25519 "
        "microvm@192.168.83.10 'touch /home/microvm/nix-secrets/.write-should-fail'"
      )

      # Bring up nixfiles VM, which switches workspace sources from placeholders to symlinks.
      host.succeed("install -d -m 0755 /home/lbischof/nixfiles")
      host.succeed("printf 'hello' > /home/lbischof/nixfiles/marker.txt")
      host.succeed("chown -R lbischof:users /home/lbischof/nixfiles")
      host.succeed("su - lbischof -c 'cd /home/lbischof/nixfiles && microvm-here -- true'")
      host.succeed("test -L /var/lib/microvm-workspaces/nixfiles")
      host.succeed("test \"$(readlink /var/lib/microvm-workspaces/nixfiles)\" = \"/home/lbischof/nixfiles\"")
      host.succeed("test -L /var/lib/microvm-workspaces/nix-secrets")
      host.succeed("test \"$(readlink /var/lib/microvm-workspaces/nix-secrets)\" = \"/home/lbischof/nix-secrets\"")

      # Existing testvm mount still points at stale placeholder until restart.
      host.fail(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/testvm/id_ed25519 "
        "microvm@192.168.83.10 'touch /home/microvm/nixfiles/hosts/microvms/testvm/.write-without-restart-should-fail'"
      )

      # Restart testvm so it picks up updated share source.
      host.succeed("systemctl restart microvm@testvm.service")
      host.wait_until_succeeds(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/testvm/id_ed25519 "
        "microvm@192.168.83.10 'test -f /home/microvm/testvm/marker.txt'"
      )

      host.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/testvm/id_ed25519 "
        "microvm@192.168.83.10 'touch /home/microvm/nixfiles/hosts/microvms/testvm/.write-should-work'"
      )
      host.succeed("test -f /home/lbischof/nixfiles/hosts/microvms/testvm/.write-should-work")
      host.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /home/lbischof/.ssh/microvm/nixfiles/id_ed25519 "
        "microvm@192.168.83.12 'test -f /home/microvm/nixfiles/marker.txt'"
      )
    '';
}
