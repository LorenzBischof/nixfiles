{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
let
  cfg = config.autoUpgrade;
in
{
  options = {
    autoUpgrade = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to periodically upgrade NixOS to the latest
          version. If enabled, a systemd timer will run
          `nixos-rebuild switch` once a day.
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
    };
  };
  config = lib.mkIf (cfg.enable && (builtins.hasAttr "rev" inputs.self)) {

    assertions = [
      {
        assertion = !config.system.autoUpgrade.enable;
        message = ''
          The options 'system.autoUpgrade.enable' and 'autoUpgrade.enable' cannot both be set.
        '';
      }
    ];
    autoUpgrade.flags = [
      "--refresh"
      "--flake ${cfg.flake}"
    ];

    systemd.services.nixos-upgrade =
      let
        nixos-rebuild = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";
      in
      {
        description = "NixOS Upgrade";

        restartIfChanged = false;
        unitConfig.X-StopOnRemoval = false;

        serviceConfig = {
          Type = "oneshot";
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
        };

        environment =
          config.nix.envVars
          // {
            inherit (config.environment.sessionVariables) NIX_PATH;
            HOME = "/root";
          }
          // config.networking.proxy.envVars;

        path = with pkgs; [
          coreutils
          gnutar
          xz.bin
          gzip
          gitMinimal
          config.nix.package.out
          config.programs.ssh.package
          jq
        ];

        script = ''
          ${nixos-rebuild} ${cfg.operation} ${toString cfg.flags}
        '';

        startAt = cfg.dates;

        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        # Check if the currently deployed revision exists on Github
        # Otherwise it could have been a manual switch --target-host
        # that is not pushed to Git yet and we do not want to downgrade.
        # This also prevents running offline, because then Github is not available
        serviceConfig.ExecCondition = pkgs.writeShellScript "check-upgrade-conditions" ''
          # Check generation age
          date_string="$(${nixos-rebuild} list-generations --json | jq -r '.[] | select(.current == true) | .date')"
          age_seconds=$(($(date +%s) - $(date -d "$date_string" +%s)))

          if ! test $age_seconds -gt 43200; then
              echo "Last generation is only $age_seconds old, not auto upgrading"
              exit 1
          fi

          if ! curl --fail-with-body --silent https://api.github.com/repos/lorenzbischof/nixfiles/commits/${inputs.self.rev or "dirty"}  >/dev/null; then
              echo "Commit ${inputs.self.rev or ""} does not exist on remote. Did you push your changes?"
              exit 1
          fi

        '';
        # Prefer not to autoupgrade when on battery
        unitConfig.ConditionACPower = true;

      };

    systemd.timers.nixos-upgrade = {
      timerConfig = {
        RandomizedDelaySec = cfg.randomizedDelaySec;
        FixedRandomDelay = cfg.fixedRandomDelay;
        Persistent = cfg.persistent;
      };
    };
  };
}
