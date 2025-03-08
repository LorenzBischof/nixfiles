{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{

  services.tiddlywiki = {
    enable = true;
    listenOptions = {
      port = 3456;
      authenticated-user-header = "Remote-Name";
    };
  };

  services.nginx.virtualHosts."wiki.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.tiddlywiki.listenOptions.port}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      enableAuthelia = true;
    };
  };

  homelab.ports = [ config.services.tiddlywiki.listenOptions.port ];
  homelab.dashboard.Services.Wiki.href = "https://wiki.${config.homelab.domain}";
}
