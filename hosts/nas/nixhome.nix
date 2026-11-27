{
  config,
  pkgs,
  lib,
  ...
}:
let
  domain = config.my.homelab.domain;
  serviceOption = lib.types.submodule {
    options = {
      href = lib.mkOption {
        type = lib.types.str;
        description = "URL for the service";
      };
      # Add other service-specific options here
    };
  };
in
{
  options.my.homelab.dashboard = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf serviceOption);
    default = { };
    description = "Dashboard services configuration";
  };
  config =
    let
      port = 7037;
    in
    {
      services.nixhome = {
        enable = true;
        address = ":${toString port}";
        settings.apps = lib.concatMapAttrs (section: items: {
          "${section}" = lib.mapAttrsToList (name: value: {
            url = value.href;
            name = name;
          }) items;
        }) config.my.homelab.dashboard;
      };
      services.nginx.virtualHosts."homepage.${domain}" = {
        forceSSL = true;
        useACMEHost = domain;
        enableAuthelia = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          proxyWebsockets = true;
          enableAuthelia = true;
        };
      };
      my.services.nixhome = {
        ports = [ port ];
        # Offline: it would fetch the apps' icons, but none is set.
        ingress.from = [ "nginx" ];
      };

    };
}
