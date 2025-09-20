{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
in
{
  services.nginx.virtualHosts."homeassistant.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://192.168.0.103:8123";
      proxyWebsockets = true;
    };
  };
}
