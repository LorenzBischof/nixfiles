{
  lib,
  pkgs,
  config,
  ...
}:
{

  networking.nameservers = [
    "1.1.1.1"
    "9.9.9.9"
  ];

  time.timeZone = "Europe/Zurich";

  system.activationScripts.diff = {
    supportsDryActivation = true;
    text = # bash
      ''
        if [[ -e /run/current-system ]]; then
          ${pkgs.nix}/bin/nix store \
            diff-closures /run/current-system "$systemConfig"
        fi
      '';
  };

  nix = {
    # https://discourse.nixos.org/t/general-question-how-to-avoid-running-out-of-memory-or-freezing-when-building-nix-derivations/55351/2
    daemonIOSchedClass = lib.mkDefault "idle";
    daemonCPUSchedPolicy = lib.mkDefault "idle";

    channel.enable = false;
    # Temporarily disable, because Nixd does not seem to work correctly.
    #package = pkgs.lix;
    package = pkgs.nixVersions.latest;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      http-connections = 128;
      max-substitution-jobs = 128;
      trusted-users = [
        "@wheel"
      ];
      substituters = [
        "https://cache.lorenzbischof.com/system?priority=42"
      ];
      trusted-public-keys = [
        "system:DAJL6xmsmoUmZOeGL8XxrEWF5pdtFGMW2+cOGyYaqgU="
      ];
      netrc-file = config.age.secrets.netrc.path;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  # put the service in top-level slice
  # so that it's lower than system and user slice overall
  # instead of only being lower in system slice
  systemd.services.nix-daemon.serviceConfig.Slice = "-.slice";
  # always use the daemon, even executed  with root
  environment.variables.NIX_REMOTE = "daemon";
}
