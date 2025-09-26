{ config, pkgs, ... }:

{
  virtualisation.incus = {
    enable = true;
    preseed = {
      networks = [
        {
          type = "bridge";
          name = "incusbr0";
        }
      ];
      storage_pools = [
        {
          name = "default";
          driver = "zfs";
          config.source = "zpool/incus";
        }
      ];
      profiles = [
        {
          name = "default";
          devices.eth0 = {
            name = "eth0";
            network = "incusbr0";
            type = "nic";
          };
          devices.root = {
            path = "/";
            pool = "default";
            type = "disk";
          };
        }
      ];
    };
  };
  networking.nftables.enable = true;

  users.users.lbischof.extraGroups = [
    "incus-admin"
  ];
  networking.firewall.trustedInterfaces = [ "incusbr0" ];
}
