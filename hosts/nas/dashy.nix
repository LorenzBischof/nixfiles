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
  config = {
    services.dashy = {
      enable = true;
      settings.sections = lib.mapAttrsToList (section: items: {
        name = section;
        items = lib.mapAttrsToList (title: value: {
          url = value.href;
          title = title;
        }) items;
      }) config.homelab.dashboard;
    };
    services.nginx.virtualHosts."homepage.${config.homelab.domain}" = {
      forceSSL = true;
      useACMEHost = config.homelab.domain;
      enableAuthelia = true;
      locations."/" = {
        root = config.services.dashy.finalDrv;
        tryFiles = "$uri /index.html";
        enableAuthelia = true;
      };
    };

  };
}
