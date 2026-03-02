{ lib, ... }:

{
  imports = [
    ./microvm.nix
    ./microvm-hostexec.nix
  ];

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
