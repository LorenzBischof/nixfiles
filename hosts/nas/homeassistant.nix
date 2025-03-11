{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  services.nginx.virtualHosts."homeassistant.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    locations."/" = {
      proxyPass = "http://192.168.0.103:8123";
      proxyWebsockets = true;
    };
  };
}
