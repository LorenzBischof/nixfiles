{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  home.packages = [
    inputs.mcp-nixos.packages.${pkgs.system}.default
    pkgs.nil
  ];

  programs.opencode = {
    enable = true;
    package = inputs.nix-ai-tools.packages.${pkgs.system}.opencode;
  };
  programs.claude-code = {
    enable = true;
    package = inputs.nix-ai-tools.packages.${pkgs.system}.claude-code;
  };
}
