{
  config,
  pkgs,
  ...
}:
{
  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.allowedBridges = [
    "virbr0"
    "br0"
  ];
  networking.bridges.br0.interfaces = [ ];
  networking.interfaces.br0.ipv4.addresses = [
    {
      address = "192.168.1.1";
      prefixLength = 24;
    }
  ];
}
