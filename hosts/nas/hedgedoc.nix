{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  services.hedgedoc = {
    enable = true;
    settings = {
      port = 52918;
      domain = "hedgedoc.${config.homelab.domain}";
      email = false;
      allowAnonymous = false;
      allowFreeURL = true;
    };
    environmentFile = config.age.secrets.hedgedoc-env.path;
  };
  services.nginx.virtualHosts."hedgedoc.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.hedgedoc.settings.port}";
      proxyWebsockets = true;
      enableAuthelia = true;
    };
  };

  homelab.ports = [ config.services.hedgedoc.settings.port ];
  homelab.dashboard.Monitoring.Hedgedoc.href = "https://hedgedoc.${config.homelab.domain}";
}
