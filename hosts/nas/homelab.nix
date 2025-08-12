{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  homelab.domain = lib.mkDefault secrets.prod-domain;
  homelab.nginx = {
    enable = true;
    acme = {
      enable = true;
      dnsProvider = "cloudflare";
      environmentFile = config.age.secrets.cloudflare-token.path;
    };
  };
}
