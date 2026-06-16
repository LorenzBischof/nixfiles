{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
let
  cfg = config.my.system.autoUpgrade;
  # Shared, single-owner textfile path (created by my.monitoring.client).
  textfileDir = config.my.monitoring.client.textfileDirectory;

  # Records the outcome of the last completed upgrade run as a node-exporter
  # textfile metric. $1 is 1 (success) or 0 (failure). Written atomically so a
  # concurrent scrape never sees a half-written file.
  upgradeMetricScript = pkgs.writeShellScript "autoupgrade-write-metric" ''
    set -euo pipefail
    dir="${textfileDir}"
    tmp="$dir/autoupgrade.prom.$$"
    {
      echo "# HELP node_autoupgrade_success Whether the last completed NixOS auto-upgrade run succeeded (1) or failed (0)."
      echo "# TYPE node_autoupgrade_success gauge"
      echo "node_autoupgrade_success $1"
      echo "# HELP node_autoupgrade_last_run_timestamp_seconds Unix time of the last completed NixOS auto-upgrade run."
      echo "# TYPE node_autoupgrade_last_run_timestamp_seconds gauge"
      echo "node_autoupgrade_last_run_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
    } > "$tmp"
    mv "$tmp" "$dir/autoupgrade.prom"
  '';

  # Records whether auto-upgrade is actually active (1) or disabled, e.g. by a
  # dirty git deploy (0). The value is the build-time `enabled` flag, so it only
  # changes on a switch; written atomically.
  statusMetricScript = pkgs.writeShellScript "autoupgrade-status-metric" ''
    set -euo pipefail
    dir="${textfileDir}"
    tmp="$dir/autoupgrade-enabled.prom.$$"
    {
      echo "# HELP node_config_autoupgrade_enabled Whether NixOS auto-upgrade is active (1) or disabled, e.g. by a dirty git deploy (0)."
      echo "# TYPE node_config_autoupgrade_enabled gauge"
      echo "node_config_autoupgrade_enabled ${if cfg.enabled then "1" else "0"}"
    } > "$tmp"
    mv "$tmp" "$dir/autoupgrade-enabled.prom"
  '';
in
{
  options.my.system.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to periodically upgrade NixOS to the latest
        version. If enabled, a systemd timer will run
        `nixos-rebuild switch` once a day.
      '';
    };
    enabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = cfg.enable && (builtins.hasAttr "rev" inputs.self);
      description = ''
        Whether autoupgrade is actually enabled. This is true only when
        both `enable` is true and the system is running from a clean git revision.
      '';
    };
    operation = lib.mkOption {
      type = lib.types.enum [
        "switch"
        "boot"
      ];
      default = "switch";
      example = "boot";
      description = ''
        Whether to run
        `nixos-rebuild switch` or run
        `nixos-rebuild boot`
      '';
    };
    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "github:kloenk/nix";
      description = ''
        The Flake URI of the NixOS configuration to build.
      '';
    };
    flags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "-I"
        "stuff=/home/alice/nixos-stuff"
        "--option"
        "extra-binary-caches"
        "http://my-cache.example.org/"
      ];
      description = ''
        Any additional flags passed to {command}`nixos-rebuild`.

        If you are using flakes and use a local repo you can add
        {command}`[ "--update-input" "nixpkgs" "--commit-lock-file" ]`
        to update nixpkgs.
      '';
    };
    dates = lib.mkOption {
      type = lib.types.str;
      default = "04:40";
      example = "daily";
      description = ''
        How often or when upgrade occurs. For most desktop and server systems
        a sufficient upgrade frequency is once a day.

        The format is described in
        {manpage}`systemd.time(7)`.
      '';
    };
    randomizedDelaySec = lib.mkOption {
      default = "0";
      type = lib.types.str;
      example = "45min";
      description = ''
        Add a randomized delay before each automatic upgrade.
        The delay will be chosen between zero and this value.
        This value must be a time span in the format specified by
        {manpage}`systemd.time(7)`
      '';
    };

    fixedRandomDelay = lib.mkOption {
      default = false;
      type = lib.types.bool;
      example = true;
      description = ''
        Make the randomized delay consistent between runs.
        This reduces the jitter between automatic upgrades.
        See {option}`randomizedDelaySec` for configuring the randomized delay.
      '';
    };
    persistent = lib.mkOption {
      default = true;
      type = lib.types.bool;
      example = false;
      description = ''
        Takes a boolean argument. If true, the time when the service
        unit was last triggered is stored on disk. When the timer is
        activated, the service unit is triggered immediately if it
        would have been triggered at least once during the time when
        the timer was inactive. Such triggering is nonetheless
        subject to the delay imposed by RandomizedDelaySec=. This is
        useful to catch up on missed runs of the service when the
        system was powered down.
      '';
    };
    textfileMetrics = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to record the outcome of each upgrade run as a
          node-exporter textfile metric (`node_autoupgrade_success`) instead
          of (or in addition to) notifying directly. Intended to be collected
          by a node exporter / Alloy and alerted on via Prometheus. Requires
          `my.monitoring.client` to be enabled (it owns the textfile directory).
        '';
      };
    };
  };
  config = lib.mkMerge [
    # Exports node_config_autoupgrade_enabled for every host that *wants*
    # auto-upgrade (cfg.enable), carrying the effective `enabled` value. Gated on
    # enable rather than enabled so a dirty deploy (enabled=false) still reports
    # 0 instead of dropping the series, which would read as "host offline"
    # rather than "auto-upgrade disabled".
    (lib.mkIf (cfg.enable && cfg.textfileMetrics.enable) {
      # The textfile directory is created by my.monitoring.client.

      # Build-time-static value, so no timer: a oneshot (RemainAfterExit) re-runs
      # on each switch where `enabled` changed (its ExecStart path changes) and
      # on boot; the textfile otherwise persists in /var/lib.
      systemd.services.autoupgrade-status = {
        description = "Export the auto-upgrade enabled-state metric for Prometheus";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = statusMetricScript;
        };
      };
    })

    (lib.mkIf cfg.enabled {
      environment.etc.git-revision.text = inputs.self.rev;

      system.autoUpgrade = {
        enable = true;
        inherit (cfg)
          operation
          flake
          flags
          dates
          randomizedDelaySec
          fixedRandomDelay
          persistent
          ;
      };

      systemd.services.nixos-upgrade = {
        serviceConfig = {
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";

          ExecCondition = pkgs.writeShellScript "check-upgrade-conditions" ''
            status="$(${pkgs.curl}/bin/curl -s "https://api.github.com/repos/lorenzbischof/nixfiles/compare/HEAD...${inputs.self.rev or ""}" | ${pkgs.jq}/bin/jq -r .status)"
            if [ "$status" = "behind" ]; then
                echo "Commit ${inputs.self.rev or ""} is behind the default branch. Updating..."
            elif [ "$status" = "ahead" ]; then
                echo "Commit ${inputs.self.rev or ""} is ahead of the default branch. Did you merge your PR?"
                exit 1
            elif [ "$status" = "identical" ]; then
                echo "Already up to date. Skipping."
                exit 1
            elif [ "$status" = "404" ]; then
                echo "Commit ${inputs.self.rev or ""} does not exist on remote. Did you push your changes?"
                exit 1
            else
                echo "Did not receive a response. Maybe you are rate-limited?"
                exit 1
            fi
          '';
        };
        # Prefer not to autoupgrade when on battery
        unitConfig.ConditionACPower = true;

        onSuccess = lib.optional cfg.textfileMetrics.enable "metric-upgrade-success.service";
        onFailure = lib.optional cfg.textfileMetrics.enable "metric-upgrade-failure.service";
      };

      systemd.services."metric-upgrade-success" = lib.mkIf cfg.textfileMetrics.enable {
        script = ''
          # A skipped run (e.g. on battery, already up to date) is neither a
          # success nor a failure, so leave the last recorded outcome untouched.
          if [ "$(systemctl show nixos-upgrade -p ConditionResult --value)" = "no" ]; then
            exit 0
          fi
          ${upgradeMetricScript} 1
        '';
      };

      systemd.services."metric-upgrade-failure" = lib.mkIf cfg.textfileMetrics.enable {
        script = "${upgradeMetricScript} 0";
      };

    })
  ];
}
