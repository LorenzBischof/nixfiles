{
  config,
  lib,
  ...
}:
let
  cfg = config.my.monitoring.client;
in
{
  options.my.monitoring.client = {
    enable = lib.mkEnableOption "node metrics exposure for the central Prometheus";

    mode = lib.mkOption {
      type = lib.types.enum [
        "pull"
        "push"
      ];
      default = "pull";
      description = ''
        How this host's node metrics reach the central Prometheus on the nas.

        - `pull`: run the Prometheus node exporter and let the nas scrape it
          directly. Use for always-on hosts reachable on a stable tailnet
          address. Lightweight; the nas can detect the host being down.
        - `push`: run Alloy locally and remote-write to the nas. Use for hosts
          the nas cannot reliably scrape (e.g. the roaming framework laptop).
          When the host is offline its series simply go stale rather than
          alerting "down".
      '';
    };

    textfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/prometheus-node-exporter-textfile";
      readOnly = true;
      description = ''
        Directory served by the node exporter / Alloy textfile collector where
        other modules drop their textfile metrics. Read-only: it is the shared
        contract between metric producers and the collector on this host.
      '';
    };

    enabledCollectors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "systemd"
        "textfile"
      ];
      example = [
        "systemd"
        "textfile"
        "processes"
      ];
      description = ''
        Node exporter collectors to enable on top of the defaults, in both
        modes (node exporter `--collector.<name>` flags / Alloy's
        `enable_collectors`), so push and pull hosts collect the same set.
      '';
    };

    instance = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = ''
        Value of the `instance` label for this host. Only applied in `push`
        mode (Alloy relabels to it); in `pull` mode the nas assigns the label
        from its scrape target.
      '';
    };

    remoteWriteUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://nas:9090/api/v1/write";
      description = ''
        Prometheus remote-write endpoint to push to in `push` mode. Uses the
        nas Tailscale MagicDNS name by default.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # 0755 so a node exporter under a (dynamic) user can read the textfiles.
    systemd.tmpfiles.settings."10-monitoring-client" = {
      ${cfg.textfileDirectory}.d = {
        mode = "0755";
      };
    };

    services.prometheus.exporters.node = lib.mkIf (cfg.mode == "pull") {
      enable = true;
      enabledCollectors = cfg.enabledCollectors;
      extraFlags = [
        "--collector.textfile.directory=${cfg.textfileDirectory}"
      ];
    };

    # Reachable for scraping over the tailnet only; trusts tailnet ACLs.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = lib.mkIf (cfg.mode == "pull") [
      config.services.prometheus.exporters.node.port
    ];

    services.alloy.enable = lib.mkIf (cfg.mode == "push") true;

    environment.etc."alloy/config.alloy" = lib.mkIf (cfg.mode == "push") {
      text = ''
        prometheus.exporter.unix "node" {
          enable_collectors = [${lib.concatMapStringsSep ", " (c: ''"${c}"'') cfg.enabledCollectors}]
          textfile {
            directory = "${cfg.textfileDirectory}"
          }
        }

        // Override the exporter's own instance/job (job="integrations/unix")
        // with the conventional job="node" + a hostname instance, so this host
        // matches the nas's instance-scoped alerts like any node exporter.
        discovery.relabel "node" {
          targets = prometheus.exporter.unix.node.targets
          rule {
            target_label = "instance"
            replacement  = "${cfg.instance}"
          }
          rule {
            target_label = "job"
            replacement  = "node"
          }
        }

        prometheus.scrape "node" {
          targets         = discovery.relabel.node.output
          forward_to      = [prometheus.remote_write.central.receiver]
          scrape_interval = "1m"
        }

        prometheus.remote_write "central" {
          endpoint {
            url = "${cfg.remoteWriteUrl}"
          }
        }
      '';
    };
  };
}
