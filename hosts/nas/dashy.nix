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
  options = {
    my.homelab.dashboard = lib.mkOption {
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
      }) config.my.homelab.dashboard;
    };
    services.nginx.virtualHosts."homepage.${domain}" = {
      forceSSL = true;
      useACMEHost = domain;
      enableAuthelia = true;
      locations."/" = {
        root = config.services.dashy.finalDrv;
        tryFiles = "$uri /index.html";
        enableAuthelia = true;
      };
    };

  };
}
