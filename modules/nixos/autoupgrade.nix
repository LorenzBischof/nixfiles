{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
let
  cfg = config.my.system.autoUpgrade;
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
  };
  config = lib.mkIf (cfg.enabled) {
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
    };

  };
}
