{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
in
{
  services.atticd = {
    enable = true;
    environmentFile = config.age.secrets.atticd-env.path;
  };
  services.nginx.virtualHosts."cache.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080";
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 2048M;
      '';
    };
  };
  my.homelab.ports = [ 8080 ];
}
