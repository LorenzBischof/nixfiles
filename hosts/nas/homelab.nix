{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
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
}
