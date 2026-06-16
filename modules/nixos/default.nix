{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [
    ./autoupgrade.nix
    ./common.nix
    ./monitoring-client.nix
    ./nginx.nix
    ./nixpkgs-age-monitor.nix
    ./detect-reboot-required.nix
    ./detect-syncthing-conflicts
  ];
}
