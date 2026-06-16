# Validate the Grafana Alloy config at build time.
#
# A reload (SIGHUP, on nixos-rebuild switch) with a bad config fails silently:
# Alloy logs an error and keeps running its last good config. Running
# `alloy validate` as a system.check turns that into a build failure instead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.alloy;

  inStore = lib.hasPrefix "${builtins.storeDir}/" (toString cfg.configPath);

  # The *.alloy files making up /etc/alloy (the same set the upstream module
  # reloads on via reloadTriggers).
  etcFiles = lib.filterAttrs (
    n: _: lib.hasPrefix "alloy/" n && lib.hasSuffix ".alloy" n
  ) config.environment.etc;

  # What `alloy run` loads: a store-path configPath as-is, otherwise the
  # /etc/alloy files gathered into one directory (validated together, so
  # duplicate component names and cross-file references are caught too).
  configDir =
    if inStore then
      cfg.configPath
    else
      pkgs.linkFarm "alloy-config" (
        lib.mapAttrsToList (n: v: {
          name = baseNameOf n;
          path = v.source;
        }) etcFiles
      );

  check = pkgs.runCommand "alloy-config-checked" { nativeBuildInputs = [ cfg.package ]; } ''
    alloy validate ${configDir}
    touch $out
  '';
in
{
  config = lib.mkIf (cfg.enable && (inStore || etcFiles != { })) {
    system.checks = [ check ];
  };
}
