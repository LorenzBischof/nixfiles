{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  services.scrutiny.enable = true;
  services.nginx.virtualHosts."scrutiny.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.scrutiny.settings.web.listen.port}";
      proxyWebsockets = true;
      enableAuthelia = true;
    };
  };

  homelab.ports = [ config.services.scrutiny.settings.web.listen.port ];
  homelab.dashboard.Monitoring.Scrutiny.href = "https://scrutiny.${config.homelab.domain}";
}
