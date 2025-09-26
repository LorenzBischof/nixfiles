{
  config,
  pkgs,
  lib,
  ...
}:
let
  syncthing-resolve-conflict = pkgs.writeShellApplication {
    name = "syncthing-resolve-conflict";
    runtimeInputs = [ pkgs.file ];
    text = builtins.readFile ./syncthing-resolve-conflict;
  };
  sway-terminal = pkgs.writeShellApplication {
    name = "sway-terminal";
    runtimeInputs = [ pkgs.jq ];
    text = builtins.readFile ./sway-terminal.sh;
  };
in
{
  home.packages = [
    syncthing-resolve-conflict
    sway-terminal
  ];
}
