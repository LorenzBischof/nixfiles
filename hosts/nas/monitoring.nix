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
      webExternalUrl = "https://prometheus.${domain}";
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

      rules = [
        ''
          groups:
          - name: node
            rules:
              - alert: DiskWillFillIn4Hours
                expr: predict_linear(node_filesystem_free_bytes{job="node"}[1h], 4 * 3600) < 0
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: Disk will fill in 4 hours
                  description: Something is filling up the disk
              - alert: ServiceDown
                expr: node_systemd_unit_state{state="failed", type="simple"} == 1
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "Systemd {{ $labels.name }} has failed"
                  description: Service failed
        ''
      ];
      alertmanagers = [
        {
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString config.services.prometheus.alertmanager.port}" ];
            }
          ];
        }
      ];
      alertmanager = {
        enable = true;
        webExternalUrl = "https://alertmanager.${domain}";
        # Defaults to listening on all interfaces
        listenAddress = "localhost";
        configuration = {
          "route" = {
            "group_by" = [
              "alertname"
              "alias"
            ];
            "group_wait" = "30s";
            "group_interval" = "2m";
            "repeat_interval" = "4h";
            "receiver" = "ntfy";
          };
          "receivers" = [
            {
              "name" = "ntfy";
              "webhook_configs" = [
                {
                  "url" = "http://${config.services.alertmanager-ntfy.settings.http.addr}/hook";
                  "send_resolved" = true;
                }
              ];
            }
          ];
        };
      };
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

    alertmanager-ntfy = {
      enable = true;
      settings = {
        http = {
          addr = "127.0.0.1:8111";
        };
        ntfy = {
          baseurl = "https://ntfy.sh";
          notification = {
            topic = secrets.ntfy-alertmanager;
            priority = ''
              status == "firing" ? "high" : "default"
            '';
            tags = [
              {
                tag = "+1";
                condition = ''status == "resolved"'';
              }
              {
                tag = "rotating_light";
                condition = ''status == "firing"'';
              }
            ];
            templates = {
              title = ''{{ if eq .Status "resolved" }}Resolved: {{ end }}{{ index .Annotations "summary" }}'';
              description = ''{{ index .Annotations "description" }}'';
            };
          };
        };
      };
    };

    nginx.virtualHosts."grafana.${domain}" = {
      forceSSL = true;
      useACMEHost = domain;
      enableAuthelia = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
        proxyWebsockets = true;
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
        enableAuthelia = true;
      };
    };
    nginx.virtualHosts."alertmanager.${domain}" = {
      forceSSL = true;
      useACMEHost = domain;
      enableAuthelia = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}";
        proxyWebsockets = true;
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
