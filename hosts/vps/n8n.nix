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
  services.n8n = {
    enable = true;
    webhookUrl = "https://webhook.${domain}";
  };

  services.nginx.virtualHosts."n8n.${domain}" = {
    forceSSL = true;

    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://localhost:5678";
      proxyWebsockets = true;
    };
  };
  services.nginx.virtualHosts."webhook.${domain}" = {
    forceSSL = true;

    listenAddresses = [ "10.0.0.238" ];
    useACMEHost = domain;
    locations."/webhook-test/" = {
      proxyPass = "http://localhost:5678";
      proxyWebsockets = true;
    };
    locations."/webhook/" = {
      proxyPass = "http://localhost:5678";
      proxyWebsockets = true;
    };
  };

  my.homelab.ports = [ 5678 ];
  #  my.homelab.dashboard.Services.n8n.href = "https://n8n.${domain}";
}
