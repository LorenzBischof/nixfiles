{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.services.nixpkgs-age-monitor;

  # Exports the build date of the running system's nixpkgs as a node-exporter
  # textfile metric. The value is an absolute timestamp (static between
  # rebuilds); the *age* is computed centrally in the Prometheus alert as
  # time() - node_nixpkgs_build_timestamp_seconds, so the threshold lives in
  # one place instead of per host.
  nixpkgsAgeScript = pkgs.writeShellScript "nixpkgs-age-check" ''
    set -euo pipefail

    # Format: 25.11.20250918.0147c2f -> extract the YYYYMMDD date component.
    nixos_version=$(cat /run/current-system/nixos-version)
    nixpkgs_date=$(echo "$nixos_version" | ${pkgs.gnused}/bin/sed 's/.*\.\([0-9]\{8\}\)\..*/\1/')
    nixpkgs_epoch=$(${pkgs.coreutils}/bin/date -d "$nixpkgs_date" +%s)

    dir="${config.my.monitoring.client.textfileDirectory}"
    tmp="$dir/nixpkgs-age.prom.$$"
    {
      echo "# HELP node_nixpkgs_build_timestamp_seconds Unix time of the nixpkgs snapshot the running system was built from."
      echo "# TYPE node_nixpkgs_build_timestamp_seconds gauge"
      echo "node_nixpkgs_build_timestamp_seconds $nixpkgs_epoch"
    } > "$tmp"
    mv "$tmp" "$dir/nixpkgs-age.prom"
  '';
in
{
  options.my.services.nixpkgs-age-monitor = {
    enable = lib.mkEnableOption "nixpkgs age monitoring";
  };

  config = lib.mkIf cfg.enable {
    # The textfile directory is created by my.monitoring.client.
    systemd = {
      services.nixpkgs-age-check = {
        description = "Export the nixpkgs build-timestamp metric for Prometheus";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = nixpkgsAgeScript;
        };
      };

      timers.nixpkgs-age-check = {
        description = "Refresh the nixpkgs build-timestamp metric";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Populate shortly after boot, then keep it fresh daily.
          OnBootSec = "5min";
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };
  };
}
