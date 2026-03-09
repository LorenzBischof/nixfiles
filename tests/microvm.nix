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
          ../hosts/framework/nixos/microvm/module.nix
        ];

        virtualisation.memorySize = 6144;
        virtualisation.cores = 4;

        my.microvms = {
          testvm = {
            ipAddress = "192.168.83.10";
            tapId = "microvm9";
            mac = "02:00:00:00:00:09";
            hypervisor = "qemu";
            extraModules = [
              ({ lib, ... }: {
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
            hypervisor = "qemu";
            extraModules = [
              ({ lib, ... }: {
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
      host.succeed("su - lbischof -c 'ssh-keygen -q -t ed25519 -N \"\" -f ~/.ssh/id_ed25519'")
      host.succeed("install -d -m 0755 /home/lbischof/.codex")
      host.succeed("printf 'hello' > /home/lbischof/testvm/marker.txt")
      host.succeed("chown -R lbischof:users /home/lbischof")

      # Start a non-nixfiles VM first. It creates a per-repo workspace bind mount.
      host.succeed("su - lbischof -c 'cd /home/lbischof/testvm && microvm-here -- true'")
      host.succeed("test -d /var/lib/microvm-workspaces/testvm")
      host.fail("test -L /var/lib/microvm-workspaces/testvm")
      host.fail("nc -z -w 2 192.168.83.10 22")

      host.succeed(
        "su - lbischof -c \"microvm -s testvm 'test -f /home/microvm/testvm/marker.txt'\""
      )
      host.succeed(
        "su - lbischof -c \"microvm -s testvm 'touch /home/microvm/testvm/.write-should-work'\""
      )
      host.succeed("test -f /home/lbischof/testvm/.write-should-work")
      host.fail(
        "su - lbischof -c \"microvm -s testvm 'touch /home/microvm/.workspaces/testvm/nix-secrets/.write-should-fail'\""
      )

      # Bring up nixfiles VM, which mounts nix-secrets for that VM profile.
      host.succeed("install -d -m 0755 /home/lbischof/nixfiles")
      host.succeed("printf 'hello' > /home/lbischof/nixfiles/marker.txt")
      host.succeed("chown -R lbischof:users /home/lbischof/nixfiles")
      host.succeed("su - lbischof -c 'cd /home/lbischof/nixfiles && microvm-here -- true'")
      host.succeed("test -d /var/lib/microvm-workspaces/nixfiles/nix-secrets")
      host.fail("test -L /var/lib/microvm-workspaces/nixfiles/nix-secrets")
      host.succeed("test \"$(findmnt -n -o SOURCE -M /var/lib/microvm-workspaces/nixfiles/nix-secrets)\" = \"/home/lbischof/nix-secrets\"")

      host.succeed(
        "su - lbischof -c \"microvm -s testvm 'touch /home/microvm/testvm/.write-after-nixfiles-vm-start'\""
      )
      host.succeed("test -f /home/lbischof/testvm/.write-after-nixfiles-vm-start")
      host.succeed(
        "su - lbischof -c \"microvm -s nixfiles 'touch /home/microvm/.workspaces/nixfiles/nix-secrets/.write-should-work'\""
      )
      host.succeed("test -f /home/lbischof/nix-secrets/.write-should-work")
      host.succeed(
        "su - lbischof -c \"microvm -s nixfiles 'test -f /home/microvm/nixfiles/marker.txt'\""
      )
      host.succeed("su - lbischof -c 'cd /home/lbischof/nixfiles && microvm-here -- true'")
      host.succeed("test \"$(findmnt -n -o SOURCE -M /var/lib/microvm-workspaces/nixfiles/nix-secrets)\" = \"/home/lbischof/nix-secrets\"")
    '';
}
