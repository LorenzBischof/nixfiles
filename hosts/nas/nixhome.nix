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
      port = builtins.substring 1 (
        builtins.stringLength config.services.nixhome.address - 1
      ) config.services.nixhome.address;
    in
    {
      services.nixhome = {
        enable = true;
        address = ":7037";
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
          proxyPass = "http://127.0.0.1:${port}";
          proxyWebsockets = true;
          enableAuthelia = true;
        };
      };
      my.homelab.ports = [ port ];

    };
}
