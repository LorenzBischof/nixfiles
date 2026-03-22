{ lib, pkgs, ... }:

{
  imports = [
    ./module.nix
    ./hostexec.nix
  ];

  # Expose the github token to microvms via a dedicated directory.
  # Must be a real file copy, not a symlink, because virtiofs passes symlinks
  # through as-is and the target (/run/agenix/...) doesn't exist inside the VM.
  systemd.tmpfiles.rules = [
    "d /run/host-github-token 0755 root root -"
  ];
  systemd.services.copy-github-token = {
    description = "Copy GitHub token for microVM access";
    after = [ "agenix.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = toString (pkgs.writeShellScript "copy-github-token" ''
        install -m 0400 -o 1000 -g root /run/agenix/github-token /run/host-github-token/github-token
      '');
    };
  };

  my.microvmHostExec.enable = true;

  # MicroVM networking setup
  systemd.network.enable = true;
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  systemd.network.netdevs."20-microbr".netdevConfig = {
    Kind = "bridge";
    Name = "microbr";
  };

  systemd.network.networks."20-microbr" = {
    matchConfig.Name = "microbr";
    addresses = [ { Address = "192.168.83.1/24"; } ];
    networkConfig = {
      ConfigureWithoutCarrier = true;
    };
  };

  systemd.network.networks."21-microvm-tap" = {
    matchConfig.Name = "microvm*";
    networkConfig.Bridge = "microbr";
  };

  networking.nat = {
    enable = true;
    internalInterfaces = [ "microbr" ];
    externalInterface = "wlp192s0";
  };
}
