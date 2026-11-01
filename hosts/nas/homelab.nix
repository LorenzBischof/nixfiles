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
  # `nixos-rebuild switch`. Upstream's answer to tailscale/tailscale#11504 is
  # tailscale-online.target, which runs `tailscale wait` and ships in the
  # package's units; nothing pulls it in unless a unit asks for it.
  systemd.services.nginx = {
    wants = [ "tailscale-online.target" ];
    after = [ "tailscale-online.target" ];
  };
}
