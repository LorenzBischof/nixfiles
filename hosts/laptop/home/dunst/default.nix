{
  config,
  pkgs,
  lib,
  ...
}:

{
  home.packages = with pkgs; [
    libnotify
  ];
  services.dunst.enable = true;
}
