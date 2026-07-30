{
  config,
  pkgs,
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

  # tailscaled can report itself ready to systemd before tailscale0 actually
  # has this address bound (tailscale/tailscale#11504), which makes nginx's
  # `-t` bind-test fail during `nixos-rebuild switch`. Wait for the address
  # before nginx runs its config test.
  services.nginx.preStart = ''
    for i in $(seq 1 30); do
      if ${pkgs.iproute2}/bin/ip -4 addr show dev tailscale0 2>/dev/null | grep -q "inet ${tailscaleIp}/"; then
        exit 0
      fi
      sleep 1
    done
    echo "timed out waiting for tailscale0 to have ${tailscaleIp}" >&2
    exit 1
  '';
}
