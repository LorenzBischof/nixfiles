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
  services.home-assistant = {
    enable = true;
    extraComponents = [
      "backup"
      "webhook"
      # Recommended for fast zlib compression
      # https://www.home-assistant.io/integrations/isal
      "isal"
      "esphome"
      "sonos"
      "homekit_controller"
      "zha"
      "lifx"
    ];
    config = {
      # The following is a subset of default_config
      # https://www.home-assistant.io/integrations/default_config/
      dhcp = { };
      history = { };
      homeassistant_alerts = { };
      logbook = { };
      media_source = { };
      mobile_app = { };
      ssdp = { };
      usb = { };
      zeroconf = { };

      "automation ui" = "!include automations.yaml";
      "automation" = [
        (import ./zha-light-button.nix {
          button = "1bfa5b7ffa81c34a7c4a9d89f8676af1";
          light = "light.eingang";
        })
        (import ./zha-light-button.nix {
          button = "e1e122811dd17a33220cd114443710a6";
          light = "light.kuche";
        })
        (import ./zha-light-button.nix {
          button = "e038f9f74dc4c2e727cd7b5bf507a4ff";
          light = "light.wohnzimmer";
        })
        (import ./zha-light-button.nix {
          button = "9e8989b727e66a27d6a11715bd438b19";
          light = "light.schlafzimmer";
        })

        {
          id = "light_kitchen_child";
          alias = "Light kitchen child";
          triggers = [
            {
              platform = "event";
              event_type = "zha_event";
              event_data.device_id = "19e27eb1e55929b65509dfbcb238c3cf";
              event_data.command = "single";
            }
          ];
          actions = [
            {
              service = "light.toggle";
              data.entity_id = "light.kuche";
            }
          ];
        }
      ];
      input_boolean.light_hold = { };
      http = {
        trusted_proxies = [
          "::1"
          "127.0.0.1"
        ];
        use_x_forwarded_for = true;
      };
    };
    lovelaceConfig.views = [
      {
        title = "Home";
        sections = [
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Lights";
                heading_style = "title";
              }
              {
                type = "tile";
                entity = "light.wohnzimmer";
              }
              {
                type = "tile";
                entity = "light.schlafzimmer";
              }
              {
                type = "tile";
                entity = "light.kuche";
              }
              {
                type = "tile";
                entity = "light.eingang";
              }
            ];
          }
        ];
      }
    ];
  };

  services.esphome.enable = true;

  # https://github.com/NixOS/nixpkgs/issues/339557#issuecomment-3361954390
  systemd.services.esphome.serviceConfig = {
    ProtectSystem = lib.mkForce "off";
    DynamicUser = lib.mkForce "false";
    User = "esphome";
    Group = "esphome";
  };
  users.users.esphome = {
    isSystemUser = true;
    home = "/var/lib/esphome";
    group = "esphome";
  };
  users.groups.esphome = { };

  services.nginx.virtualHosts."esphome.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://[::1]:${toString config.services.esphome.port}";
      proxyWebsockets = true;
    };
  };

  services.nginx.virtualHosts."homeassistant.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    extraConfig = ''
      proxy_buffering off;
    '';
    locations."/" = {
      proxyPass = "http://localhost:8123";
      proxyWebsockets = true;
    };
  };

  # Required by Lifx
  networking.firewall.allowedUDPPorts = [ 56700 ];

  # Required by Sonos
  networking.firewall.allowedTCPPorts = [ 1400 ];

  # Required by Homekit
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };
}
