{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:
{
  services.atticd = {
    enable = true;
    environmentFile = config.age.secrets.atticd-env.path;
  };
  services.nginx.virtualHosts."cache.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080";
      proxyWebsockets = true;
    };
  };
  homelab.ports = [ 8080 ];
}
