{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.my.programs.orca.enable =
    lib.mkEnableOption "Orca, the desktop app for parallel coding agents";

  # Pairs with the runtime on the vps: see hosts/vps/orca.nix.
  config = lib.mkIf config.my.programs.orca.enable {
    home.packages = [ pkgs.llm-agents.orca ];
  };
}
