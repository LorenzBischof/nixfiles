{
  config,
  pkgs,
  secrets,
  ...
}:
let
  inherit (config.my.homelab) domain;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";

  # Dead man's switch timing. The delay must exceed the re-send interval so each
  # re-send reschedules the held ntfy message before it can deliver; on failure
  # the alarm fires up to one delay later.
  watchdogDelay = "90m";
  watchdogInterval = "30m";

  # Keeps the ntfy "heartbeat-watchdog" notification in sync with the dead man's
  # switch. Both modes reconcile against watchdog_armed (see below): clear
  # (frequent) heals the DOWN notification on recovery, nag (daily) re-fires the
  # alert while the switch stays down.
  watchdogCheckScript = pkgs.writeShellScript "watchdog-check" ''
    set -euo pipefail

    topic="https://ntfy.sh/${secrets.ntfy-alertmanager}"

    # The single source of truth for pipeline health: a scheduled (undelivered)
    # Watchdog message in ntfy means the switch is still deferring its firing
    # into the future, so the whole pipeline (Prometheus -> Alertmanager ->
    # bridge -> ntfy) is healthy. Its absence means the switch has fired and not
    # re-armed -> something in that chain is down.
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
        # Recovery: armed again, so heal the DOWN notification within minutes
        # instead of waiting for the daily nag. Only acts while armed, so it can
        # never dismiss an active nag during an outage.
        if watchdog_armed; then
          ${pkgs.curl}/bin/curl -fsS -X PUT "$topic/heartbeat-watchdog/clear" > /dev/null || true
        fi
        ;;
      nag)
        # Still down: (re)publish the alert. ntfy re-alerts on each daily update,
        # even after a dismissal.
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
  systemd.tmpfiles.settings."10-monitoring" = {
    ${textfileDir}.d = { };
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
              # vps is always-on and reachable on its stable tailnet IP.
              targets = [
                "100.91.84.39:${toString config.services.prometheus.exporters.node.port}"
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
              # Scoped to instance="nas": these always-on-host alerts must not
              # fire for the roaming framework laptop (which shares job="node").
              # To cover another always-on host (e.g. vps) add it here, e.g.
              # instance=~"nas|vps".
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
              # Fires per host whose running system's nixpkgs is older than the
              # threshold. The age is derived from the exported build timestamp,
              # so the threshold lives here instead of on each host. While a host
              # is offline its series goes stale and the alert does not evaluate.
              # Expression value is the age in days, so {{ $value }} renders it
              # in the notification.
              - alert: NixpkgsOutdated
                expr: (time() - node_nixpkgs_build_timestamp_seconds) / 86400 > 7
                for: 1h
                labels:
                  severity: warning
                annotations:
                  summary: "nixpkgs is outdated on {{ $labels.instance }}"
                  description: "The running system's nixpkgs is {{ $value | printf \"%.0f\" }} days old."
          - name: autoupgrade
            rules:
              # No host filter: fires for any host exporting the gauge (every
              # host that auto-upgrades, identified by its instance label).
              # Fires when the last completed auto-upgrade run failed; the
              # subsequent successful run flips the gauge back to 1, resolving
              # the alert -> the resolved ntfy notification is the "recovered"
              # signal. While a host is offline the series goes stale.
              - alert: AutoUpgradeFailed
                expr: node_autoupgrade_success == 0
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "NixOS auto-upgrade failed on {{ $labels.instance }}"
                  description: "The last completed auto-upgrade run on {{ $labels.instance }} failed."
              # Fires when a host that wants auto-upgrade has had it disabled
              # (gauge 0, e.g. a dirty git deploy) at every scrape for the past
              # week and never re-enabled. max_over_time over a range tolerates
              # offline gaps (unlike `for:`, which resets when an intermittent
              # host's series goes stale), so this works for the roaming laptop.
              # Needs TSDB retention >= 1w (default 15d).
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
            # Re-send the always-firing Watchdog every interval so the bridge
            # reschedules the ntfy switch (delay > interval). send_resolved=false:
            # a resolve (e.g. Prometheus stops) would overwrite the armed firing
            # message via the shared X-Sequence-ID instead of letting it fire.
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
                  # Independent external dead-man's switch: pinged on each firing
                  # re-send, so a Prometheus/Alertmanager/NAS failure stops the pings
                  # and healthchecks.io alerts through a path separate from ntfy (and
                  # can escalate/repeat via its own notification integrations).
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
              # Turn the Watchdog alert into a self-replacing ntfy scheduled
              # message: delivered one delay in the future, replaced on every
              # re-send via the shared sequence id. Both headers render empty
              # for all other alerts, which ntfy ignores (so real alerts are
              # delivered immediately, as before).
              headers = {
                "X-Delay" = ''{{ if eq (index .Labels "alertname") "Watchdog" }}${watchdogDelay}{{ end }}'';
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
