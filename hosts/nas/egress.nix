{ config, lib, ... }:
let
  # Services that need nothing beyond this host. A supply-chain compromise of
  # one of them then can't call home, open a reverse tunnel or reach the LAN
  # and tailnet. systemd filters both directions, so this also keeps them from
  # being reached from anywhere but loopback, where nginx and the other local
  # clients are. None of them resolves names beyond /etc/hosts, so they also
  # lose resolved, which would forward a lookup upstream and leave a DNS
  # tunnel open. Still open: other loopback services that fetch URLs on
  # request can relay for them.
  #
  # Not here: scrutiny-collector runs as root, which could move itself out of
  # its cgroup and leave the filter behind. paperless-task-queue fetches mail
  # when mail accounts are set up in Paperless.
  localOnly = [
    "authelia-main" # users file, filesystem notifier, redis over a socket
    "scrutiny"
    "influxdb2"
    # monitoring-client.nix opens its port on tailscale0, but only the local
    # Prometheus scrapes it.
    "prometheus-node-exporter"
    "postgresql"
    "paperless-web"
    "paperless-consumer" # also what paperless-backup copies its sandbox from
    "paperless-scheduler"
  ]
  ++ lib.mapAttrsToList (name: _: "redis-${name}") (
    lib.filterAttrs (_: server: server.enable) config.services.redis.servers
  );
in
{
  systemd.services = lib.genAttrs localOnly (_: {
    serviceConfig = {
      IPAddressDeny = "any";
      # Not "localhost": that is 127.0.0.0/8, which holds resolved's stub on
      # 127.0.0.53.
      IPAddressAllow = [
        "127.0.0.1"
        "::1"
      ];
      # Unix sockets that would resolve names for them, which the IP filter
      # doesn't see: nscd's and nss-resolve's varlink one. /etc/hosts still
      # answers localhost.
      InaccessiblePaths = [
        "-/run/nscd"
        "-/run/systemd/resolve"
      ];
    };
  });
}
