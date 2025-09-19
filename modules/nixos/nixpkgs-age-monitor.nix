{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixpkgs-age-monitor;

  nixpkgsAgeScript = pkgs.writeShellScript "nixpkgs-age-check" ''
    set -euo pipefail
    
    # Extract date from nixos-version (format: 25.11.20250918.0147c2f)
    nixos_version=$(cat /run/current-system/nixos-version)
    nixpkgs_date=$(echo "$nixos_version" | sed 's/.*\.\([0-9]\{8\}\)\..*/\1/')
    
    # Convert to epoch seconds for calculation
    nixpkgs_epoch=$(date -d "$nixpkgs_date" +%s)
    current_epoch=$(date +%s)
    
    # Calculate age in days
    age_days=$(( (current_epoch - nixpkgs_epoch) / 86400 ))
    
    echo "nixpkgs age: $age_days days"
    
    # Send notification if threshold exceeded
    if [ "$age_days" -gt "${toString cfg.alertThresholdDays}" ]; then
      ${pkgs.curl}/bin/curl -s \
        -H "Title: nixpkgs outdated on $(${pkgs.nettools}/bin/hostname)" \
        -H "Priority: default" \
        -H "Tags: warning" \
        -d "nixpkgs is $age_days days old (built: $nixpkgs_date)" \
        "${cfg.ntfyUrl}/${cfg.ntfyTopic}"
    fi
  '';
in
{
  options.services.nixpkgs-age-monitor = {
    enable = lib.mkEnableOption "nixpkgs age monitoring";
    
    alertThresholdDays = lib.mkOption {
      type = lib.types.int;
      default = 7;
      description = "Alert when nixpkgs is older than this many days";
    };
    
    ntfyUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.sh";
      description = "ntfy server URL";
    };
    
    ntfyTopic = lib.mkOption {
      type = lib.types.str;
      description = "ntfy topic for notifications";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd = {
      services.nixpkgs-age-check = {
        description = "Check nixpkgs age and send ntfy alert if outdated";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = nixpkgsAgeScript;
          User = "nobody";
          Group = "nogroup";
        };
      };

      timers.nixpkgs-age-check = {
        description = "Daily nixpkgs age check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };
  };
}