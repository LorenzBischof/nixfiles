{
  config,
  pkgs,
  secrets,
  ...
}:
let
  inherit (config.homelab) domain;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
in
{
  systemd.tmpfiles.settings."10-monitoring" = {
    ${textfileDir}.d = { };
  };

  # https://grahamc.com/blog/nixos-system-version-prometheus/
  system.activationScripts.node-exporter-system-version = ''
    cd ${textfileDir}
    (
      echo -n "system_version ";
      readlink /nix/var/nix/profiles/system | cut -d- -f2
    ) > system-version.prom.next
    mv system-version.prom.next system-version.prom
  '';

  services = {
    prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [
        "systemd"
        "processes"
        "textfile"
      ];
      extraFlags = [
        "--collector.textfile.directory=${textfileDir}"
      ];
    };
    prometheus = {
      enable = true;
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [
                "localhost:${toString config.services.prometheus.exporters.node.port}"
              ];
            }
          ];
        }
        {
          job_name = "restic";
          static_configs = [
            {
              targets = [
                "localhost:${toString config.services.prometheus.exporters.restic.port}"
              ];
            }
          ];
        }
      ];
    };

    grafana = {
      enable = true;
      settings = {
        server = {
          domain = "grafana.${domain}";
        };
        auth.disable_login_form = true;
        "auth.anonymous" = {
          enabled = true;
          org_role = "Admin";
        };
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "prometheus";
            type = "prometheus";
            url = "http://127.0.0.1:${toString config.services.prometheus.port}";
            isDefault = true;
          }
        ];
        dashboards.settings.providers = [
          {
            options.path = ./dashboards;
          }
        ];
      };
    };

    nginx.virtualHosts."grafana.${domain}" = {
      forceSSL = true;
      useACMEHost = domain;
      enableAuthelia = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
        proxyWebsockets = true;
        recommendedProxySettings = true;
        enableAuthelia = true;
      };
    };

    nginx.virtualHosts."prometheus.${domain}" = {
      forceSSL = true;
      useACMEHost = domain;
      enableAuthelia = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
        proxyWebsockets = true;
        recommendedProxySettings = true;
        enableAuthelia = true;
      };
    };
  };

  homelab.ports = [
    config.services.prometheus.port
    config.services.grafana.settings.server.http_port
    config.services.prometheus.exporters.restic.port
    config.services.prometheus.exporters.node.port
  ];
  homelab.dashboard.Monitoring = {
    Grafana = {
      href = "https://${config.services.grafana.settings.server.domain}";
    };
    Prometheus = {
      href = "https://prometheus.${domain}";
    };
  };
}
