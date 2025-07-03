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

  services.thermald.enable = true;
  services.auto-cpufreq = {
    enable = true;
    settings = {
      charger = {
        governor = "powersave";
        turbo = "auto";
      };
    };
  };

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

    package = pkgs.lix;
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
        "https://nix-community.cachix.org?priority=41"
        "https://billowing-darkness-4823.fly.dev/system?priority=42"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "system:8c8bXDuMT8ZPBj+//XtB6JXJWrZQf7IdOPHhoWL8Pr8="
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
