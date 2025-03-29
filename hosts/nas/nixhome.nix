{
  config,
  pkgs,
  lib,
  ...
}:
let
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
  options = {
    homelab.dashboard = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf serviceOption);
      default = { };
      description = "Dashboard services configuration";
    };
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
        }) config.homelab.dashboard;
      };
      services.nginx.virtualHosts."homepage.${config.homelab.domain}" = {
        forceSSL = true;
        useACMEHost = config.homelab.domain;
        enableAuthelia = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${port}";
          proxyWebsockets = true;
          enableAuthelia = true;
        };
      };
      homelab.ports = [ port ];

    };
}
