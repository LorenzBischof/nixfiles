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
  services.scrutiny.enable = true;
  services.nginx.virtualHosts."scrutiny.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.scrutiny.settings.web.listen.port}";
      proxyWebsockets = true;
      enableAuthelia = true;
    };
  };

  my.homelab.ports = [ config.services.scrutiny.settings.web.listen.port ];
  my.homelab.dashboard.Monitoring.Scrutiny.href = "https://scrutiny.${domain}";
}
