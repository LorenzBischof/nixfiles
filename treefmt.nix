{ pkgs, ... }:
{
  projectRootFile = "flake.nix";
  programs.nixfmt.enable = true;
  programs.ruff-format.enable = true;
}
