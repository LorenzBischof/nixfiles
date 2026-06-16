{
  config,
  pkgs,
  secrets,
  ...
}:
let
  inherit (config.my.homelab) domain;
  # Single-owner path, created by my.monitoring.client.
  textfileDir = config.my.monitoring.client.textfileDirectory;

  # Delay must exceed the re-send interval so each re-send reschedules the held
  # ntfy message before it delivers; on failure it fires up to one delay later.
  watchdogDelay = "90m";
  watchdogInterval = "30m";

  # Reconciles the "heartbeat-watchdog" notification against watchdog_armed:
  # clear (frequent) heals it on recovery, nag (daily) re-fires while down.
  watchdogCheckScript = pkgs.writeShellScript "watchdog-check" ''
    set -euo pipefail

    topic="https://ntfy.sh/${secrets.ntfy-alertmanager}"

    # Pipeline health = a scheduled (undelivered) Watchdog message exists in
    # ntfy. Its absence means the switch has fired -> something is down.
    watchdog_armed() {
      local pending
      pending=$(${pkgs.curl}/bin/curl -fsS --get "$topic/json" \
        --data-urlencode "poll=1" \
        --data-urlencode "sched=1" \
        --data-urlencode "since=0s" \
        --data-urlencode "tags=alertname = Watchdog")
      [ -n "$pending" ]
    }

    case "''${1:-}" in
      clear)
        # Only acts while armed, so it can't dismiss an active nag mid-outage.
        if watchdog_armed; then
          ${pkgs.curl}/bin/curl -fsS -X PUT "$topic/heartbeat-watchdog/clear" > /dev/null || true
        fi
        ;;
      nag)
        # Still down: (re)publish. ntfy re-alerts on each update, even if dismissed.
        if ! watchdog_armed; then
          ${pkgs.curl}/bin/curl -fsS \
            -H "Title: NAS monitoring dead man's switch is not armed" \
            -H "Priority: high" \
            -H "Tags: rotating_light" \
            -d "No Watchdog heartbeat is scheduled on ntfy: the switch has fired and the pipeline is still down, or it is misconfigured. Repeats daily until armed." \
            "$topic/heartbeat-watchdog"
        fi
        ;;
    esac
  '';
in
{
  # Scraped locally by its own Prometheus (pull); see scrapeConfigs below.
  my.monitoring.client = {
    enable = true;
    mode = "pull";
    enabledCollectors = [
      "systemd"
      "processes"
      "textfile"
    ];
  };

  systemd.services.watchdog-clear = {
    description = "Clear the ntfy DOWN notification once the dead man's switch re-arms";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${watchdogCheckScript} clear";
      User = "nobody";
      Group = "nogroup";
    };
  };

  systemd.timers.watchdog-clear = {
    description = "Frequently clear the DOWN notification after recovery";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10";
      Persistent = true;
    };
  };

  systemd.services.watchdog-nag = {
    description = "Re-publish the ntfy DOWN alert while the dead man's switch is not armed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${watchdogCheckScript} nag";
      User = "nobody";
      Group = "nogroup";
    };
  };

  systemd.timers.watchdog-nag = {
    description = "Daily re-trigger of the DOWN alert while not armed";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
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
    prometheus = {
      enable = true;
      webExternalUrl = "https://prometheus.${domain}";
      # Accept remote_write from intermittently-online hosts (e.g. the framework
      # laptop via Alloy) that the nas cannot reliably scrape itself. Reachable
      # only over Tailscale (see firewall rule below).
      extraFlags = [ "--web.enable-remote-write-receiver" ];
      scrapeConfigs = [
        {
          # Every node exporter shares job="node"; hosts are told apart by the
          # instance label. nas and vps are always-on and scraped directly here.
          # The roaming framework laptop remote-writes itself with the same
          # job="node" (see hosts/framework/nixos/monitoring.nix). Host-scoped
          # alerts below therefore select on instance, never on job.
          job_name = "node";
          static_configs = [
            {
              targets = [
                "localhost:${toString config.services.prometheus.exporters.node.port}"
              ];
              labels.instance = "nas";
            }
            {
              # vps is always-on and reachable on its Tailscale MagicDNS name.
              targets = [
                "vps:${toString config.services.prometheus.exporters.node.port}"
              ];
              labels.instance = "vps";
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
              # Scoped to instance="nas" so these always-on-host alerts don't
              # fire for the roaming laptop. Add hosts via instance=~"nas|vps".
              - alert: DiskWillFillIn4Hours
                expr: predict_linear(node_filesystem_free_bytes{instance="nas"}[1h], 4 * 3600) < 0
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: Disk will fill in 4 hours
                  description: Something is filling up the disk
              - alert: ServiceDown
                expr: node_systemd_unit_state{instance="nas", state="failed", type="simple"} == 1
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "Systemd {{ $labels.name }} has failed"
                  description: Service failed
              # last_over_time bridges scrape gaps so the sleeping laptop doesn't
              # spuriously resolve; it tracks the current system, so a rollback to
              # older nixpkgs re-fires (max_over_time would mask it). $value is the
              # age in days. Needs TSDB retention >= 1w.
              - alert: NixpkgsOutdated
                expr: (time() - last_over_time(node_nixpkgs_build_timestamp_seconds[1w])) / 86400 > 7
                labels:
                  severity: warning
                annotations:
                  summary: "nixpkgs is outdated on {{ $labels.instance }}"
                  description: "The running system's nixpkgs is {{ $value | printf \"%.0f\" }} days old."
          - name: autoupgrade
            rules:
              # Fires when the last auto-upgrade run failed; the next successful
              # run flips the gauge to 1 and resolves it. last_over_time bridges
              # scrape gaps so the sleeping laptop doesn't spuriously resolve.
              # Needs TSDB retention >= 1w.
              - alert: AutoUpgradeFailed
                expr: last_over_time(node_autoupgrade_success[1w]) == 0
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "NixOS auto-upgrade failed on {{ $labels.instance }}"
                  description: "The last completed auto-upgrade run on {{ $labels.instance }} failed."
              # Fires when auto-upgrade has been disabled (gauge 0) for a whole
              # week (e.g. a dirty git deploy). max_over_time over a range
              # tolerates offline gaps (unlike `for:`, which resets on stale
              # series). Needs TSDB retention >= 1w.
              - alert: AutoUpgradeDisabled
                expr: max_over_time(node_config_autoupgrade_enabled[1w]) == 0
                for: 30m
                labels:
                  severity: warning
                annotations:
                  summary: "NixOS auto-upgrade disabled on {{ $labels.instance }}"
                  description: "Auto-upgrade has been disabled on {{ $labels.instance }} for over a week (likely a dirty git deploy); the host is not receiving automatic updates."
          - name: watchdog
            rules:
              # Always-firing, routed every 30m. The bridge turns it into a
              # self-replacing scheduled ntfy message (X-Delay 90m) pushed into
              # the future while healthy, delivered if the pipeline breaks. The
              # annotations describe the failure condition.
              - alert: Watchdog
                expr: vector(1)
                labels:
                  severity: none
                annotations:
                  summary: "NAS monitoring pipeline is DOWN"
                  description: "No Watchdog heartbeat reached ntfy for over ${watchdogDelay}. Prometheus, Alertmanager, the alertmanager-ntfy bridge, or the NAS itself is down."
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
            # Re-send the Watchdog every interval so the bridge reschedules the
            # ntfy switch (delay > interval). send_resolved=false: a resolve would
            # overwrite the armed message via X-Sequence-ID instead of firing it.
            "routes" = [
              {
                "matchers" = [ ''alertname="Watchdog"'' ];
                "receiver" = "watchdog";
                "group_wait" = "0s";
                "repeat_interval" = watchdogInterval;
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
            {
              "name" = "watchdog";
              "webhook_configs" = [
                {
                  "url" = "http://${config.services.alertmanager-ntfy.settings.http.addr}/hook";
                  "send_resolved" = false;
                }
                {
                  # Independent dead-man's switch: pinged on each firing re-send,
                  # so a pipeline/NAS failure stops the pings and healthchecks.io
                  # alerts through a path separate from ntfy.
                  "url" = "https://hc-ping.com/${secrets.healthchecks-watchdog}";
                  "send_resolved" = false;
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
              # Watchdog: X-Delay schedules it into the future, shared
              # X-Sequence-ID makes each re-send replace it. X-Delay is empty for
              # other alerts (delivered immediately). Every other alert uses its
              # fingerprint as the sequence id; it's stable across re-sends and the
              # resolved message, so ntfy updates one notification instead of
              # stacking.
              headers = {
                "X-Delay" = ''{{ if eq (index .Labels "alertname") "Watchdog" }}${watchdogDelay}{{ end }}'';
                "X-Sequence-ID" = ''{{ if eq (index .Labels "alertname") "Watchdog" }}heartbeat-watchdog{{ else }}{{ .Fingerprint }}{{ end }}'';
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

  # Expose the Prometheus remote_write receiver to other tailnet hosts only.
  # The public UI stays behind nginx + Authelia; this opens the raw port solely
  # on the Tailscale interface, trusting tailnet ACLs for authentication.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    config.services.prometheus.port
  ];

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
