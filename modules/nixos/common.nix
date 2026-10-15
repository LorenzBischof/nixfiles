{
  lib,
  pkgs,
  config,
  inputs,
  secrets,
  ...
}:
{
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;

  networking.nameservers = [
    "1.1.1.1"
    "9.9.9.9"
  ];

  time.timeZone = "Europe/Zurich";

  # Crash-looping services back off 1min between restarts (systemd default is
  # 100ms), so a broken unit can't hammer in a tight loop. Override per-unit.
  systemd.settings.Manager.DefaultRestartSec = "1min";

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
        # Our own binary cache. The URL lives in nix-secrets to keep it out of
        # this public repo, unencrypted there because nix needs it at eval time;
        # it carries `priority` because nix reads that from the client, not from
        # the bucket's nix-cache-info. CI holds the same string.
        secrets.s3-cache-store-url
      ];
      trusted-public-keys = [
        # `nix key convert-secret-to-public` on the CI signing key, which lives
        # only in the NIX_CACHE_SIGNING_KEY GitHub secret.
        "s3:g+tSfjDOsI+PlY7ZGs981O+IIAYadMSzSz4NMm/kwIk="
      ];
      # No `fallback` override: nix's default of false is what we want. An
      # unreachable or unauthenticated cache is only a warning and builds from
      # source either way; fallback would additionally hide a *corrupt or
      # interrupted* download behind a silent source rebuild, which on vps
      # costs hours. Better to fail and let the next upgrade run retry.
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
  # Builds using the daemon get the S3 cache's read-only key from its
  # environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
  systemd.services.nix-daemon.serviceConfig.EnvironmentFile =
    config.age.secrets.nix-daemon-env.path;
  # Prefer the daemon in login sessions. Rebuilds must evaluate and build as
  # the user (nixos-rebuild --elevate sudo), not under sudo: sudo strips this
  # and root would then bypass the daemon, losing the cache credentials.
  environment.variables.NIX_REMOTE = "daemon";
}
