{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  mediaDir = "${config.services.home-assistant.configDir}/media";
in
{
  systemd.tmpfiles.settings."10-homeassistant".${mediaDir}.d = {
    user = "hass";
    group = "hass";
  };
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
          light = "light.living_room";
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

        {
          id = "light_livingroom_child";
          alias = "Light livingroom child";
          triggers = [
            {
              platform = "event";
              event_type = "zha_event";
              event_data.device_id = "af7e099abfd813adda3107f88fff9064";
              event_data.args.click_type = "single";
            }
          ];
          actions = [
            {
              service = "light.toggle";
              data.entity_id = "light.living_room";
            }
          ];
        }
      ];
      http = {
        trusted_proxies = [
          "::1"
          "127.0.0.1"
        ];
        use_x_forwarded_for = true;
      };
      homeassistant.media_dirs.media = mediaDir;
    };
    blueprints.automation = [
      ./nfc-media.yaml
    ];
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
                entity = "light.living_room";
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

  # ESPHome dropped the built-in dashboard in 2026.8, so services.esphome would
  # only add a unit that crash-loops. Inline the rest of that module -- user,
  # group, state dir and the CLI -- and flash from the command line instead.
  #
  # https://github.com/NixOS/nixpkgs/issues/563986 tracks this; the module is
  # being converted to ESPHome Device Builder in
  # https://github.com/NixOS/nixpkgs/pull/550245. Once that is merged, drop this
  # block and go back to services.esphome.enable (plus the esphome.${domain}
  # nginx vhost proxying to config.services.esphome.port).
  users.users.esphome = {
    isSystemUser = true;
    home = "/var/lib/esphome";
    group = "esphome";
  };
  users.groups.esphome = { };
  systemd.tmpfiles.settings."10-esphome"."/var/lib/esphome".d = {
    user = "esphome";
    group = "esphome";
    mode = "0750";
  };
  environment.systemPackages = [ pkgs.esphome ];

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
  networking.firewall.allowedTCPPorts = [
    1400 # Sonos event callbacks
    8123 # Home Assistant (LAN access for fetching media by Sonos)
  ];

  # Required by Homekit
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };
}
