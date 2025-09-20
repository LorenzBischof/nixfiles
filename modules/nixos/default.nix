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
    ./nginx.nix
    ./nixpkgs-age-monitor.nix
  ];
}
