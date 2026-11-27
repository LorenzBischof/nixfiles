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

  # Both listen on every address and need nothing beyond loopback.
  my.services = {
    scrutiny = {
      ports = [ config.services.scrutiny.settings.web.listen.port ];
      ingress.from = [
        "nginx"
        # Posts the SMART data.
        "scrutiny-collector"
      ];
    };
    influxdb2 = {
      ports = [ config.services.scrutiny.settings.web.influxdb.port ];
      ingress.from = [ "scrutiny" ];
    };
  };
  my.homelab.dashboard.Monitoring.Scrutiny.href = "https://scrutiny.${domain}";
}
