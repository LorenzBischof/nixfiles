{
  config,
  lib,
  secrets,
  ...
}:
let
  tailscaleIp = "100.102.187.46";
in
{
  my.homelab = {
    domain = lib.mkDefault secrets.prod-domain;
    nginx = {
      enable = true;
      acme = {
        enable = true;
        dnsProvider = "cloudflare";
        environmentFile = config.age.secrets.cloudflare-token.path;
      };
    };
  };

  services.nginx.defaultListenAddresses = [ tailscaleIp ];

  # tailscaled reports itself ready to systemd before tailscale0 actually has
  # this address bound, which makes nginx's `-t` bind-test fail during
  # `nixos-rebuild switch`. Wait for the address before nginx runs its config
  # test. `tailscale wait` is upstream's answer to tailscale/tailscale#11504; the
  # tailscale-online.target it also added ships in the package but isn't wired
  # up by the NixOS module.
  #
  # `tailscale wait` needs AF_NETLINK to verify that the address is present on
  # the interface, which nginx.service does not otherwise allow.
  systemd.services.nginx.serviceConfig.RestrictAddressFamilies = [ "AF_NETLINK" ];

  services.nginx.preStart = ''
    ${lib.getExe config.services.tailscale.package} wait --timeout=30s
  '';
}
