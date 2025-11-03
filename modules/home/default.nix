{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [
    ./wayland
    ./shell
    ./git
    ./firefox.nix
  ];
}
