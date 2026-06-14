{ config, ... }:
let
  # Same directory the auto-upgrade unit writes its outcome metric to.
  textfileDir = config.my.system.autoUpgrade.textfileMetrics.directory;
in
{
  # The framework laptop is only intermittently online and roams networks, so
  # the nas cannot reliably scrape it. Instead Alloy runs the node exporter
  # locally and remote-writes to the nas Prometheus over Tailscale. When the
  # laptop is offline the series simply go stale rather than alerting "down".
  services.alloy.enable = true;

  environment.etc."alloy/config.alloy".text = ''
    prometheus.exporter.unix "node" {
      textfile {
        directory = "${textfileDir}"
      }
    }

    // Identify this node explicitly so dashboards/alerts read "framework"
    // rather than a loopback address.
    discovery.relabel "node" {
      targets = prometheus.exporter.unix.node.targets
      rule {
        target_label = "instance"
        replacement  = "framework"
      }
      // The unix exporter tags its own targets job="integrations/unix". Force
      // the conventional job="node" so framework is just another node exporter,
      // identified by instance="framework". The nas's host-scoped alerts select
      // on instance, not job, so this no longer pulls framework into the
      // always-on-nas alerts (see hosts/nas/monitoring.nix).
      rule {
        target_label = "job"
        replacement  = "node"
      }
    }

    prometheus.scrape "node" {
      targets         = discovery.relabel.node.output
      forward_to      = [prometheus.remote_write.nas.receiver]
      scrape_interval = "1m"
    }

    prometheus.remote_write "nas" {
      endpoint {
        url = "http://nas:9090/api/v1/write"
      }
    }
  '';
}
