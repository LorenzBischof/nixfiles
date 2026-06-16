{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [
    ./alloy-validate.nix
    ./autoupgrade.nix
    ./common.nix
    ./monitoring-client.nix
    ./nginx.nix
    ./nixpkgs-age-monitor.nix
    ./detect-reboot-required.nix
    ./detect-syncthing-conflicts
  ];
}
