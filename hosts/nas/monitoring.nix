{
  config,
  pkgs,
  secrets,
  ...
}:
let
  inherit (config.my.homelab) domain;
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
          - name: watchdog
            rules:
              # Always-firing alert. Routed every 30m through the real
              # Alertmanager -> alertmanager-ntfy path, where the bridge turns it
              # into a self-replacing ntfy scheduled message (X-Delay 90m, same
              # X-Sequence-ID). While the whole pipeline is healthy the message
              # keeps getting pushed into the future and is never delivered. If
              # Prometheus stops evaluating, Alertmanager stops dispatching, the
              # bridge breaks, or the NAS dies, the held alert fires. The
              # annotations therefore describe the *failure* condition.
              - alert: Watchdog
                expr: vector(1)
                labels:
                  severity: none
                annotations:
                  summary: "NAS monitoring pipeline is DOWN"
                  description: "No Watchdog heartbeat reached ntfy for over 90m. Prometheus, Alertmanager, the alertmanager-ntfy bridge, or the NAS itself is down."
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
            # Re-send the always-firing Watchdog every 30m so the bridge keeps
            # rescheduling the ntfy dead man's switch (X-Delay 90m > 30m).
            "routes" = [
              {
                "matchers" = [ ''alertname="Watchdog"'' ];
                "receiver" = "ntfy";
                "group_wait" = "0s";
                "repeat_interval" = "30m";
              }
            ];
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
        # https://github.com/NixOS/nixpkgs/pull/484374
        security.secret_key = "SW2YcwTIb9zpOOhoPsMm";
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
              # Turn the Watchdog alert into a self-replacing ntfy scheduled
              # message: delivered 90m in the future, replaced on every 30m
              # re-send via the shared sequence id. Both headers render empty
              # for all other alerts, which ntfy ignores (so real alerts are
              # delivered immediately, as before).
              headers = {
                "X-Delay" = ''{{ if eq (index .Labels "alertname") "Watchdog" }}90m{{ end }}'';
                "X-Sequence-ID" = ''{{ if eq (index .Labels "alertname") "Watchdog" }}heartbeat-watchdog{{ end }}'';
              };
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

  my.homelab.ports = [
    config.services.prometheus.port
    config.services.grafana.settings.server.http_port
    config.services.prometheus.exporters.restic.port
    config.services.prometheus.exporters.node.port
  ];
  my.homelab.dashboard.Monitoring = {
    Grafana = {
      href = "https://${config.services.grafana.settings.server.domain}";
    };
    Prometheus = {
      href = "https://prometheus.${domain}";
    };
  };
}
