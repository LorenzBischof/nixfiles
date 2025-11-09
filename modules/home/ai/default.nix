{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  cfg = config.my.profiles.ai;
in
{
  imports = [
    ./aichat.nix
  ];
  options.my.profiles.ai.enable = lib.mkEnableOption "ai";
  config = lib.mkIf cfg.enable {
    home.packages = [
      inputs.mcp-nixos.packages.${pkgs.system}.default
      pkgs.nil
    ];
    services.ollama.enable = true;

    programs.opencode = {
      enable = true;
      package = inputs.nix-ai-tools.packages.${pkgs.system}.opencode;
    };
    programs.claude-code = {
      enable = true;
      package = inputs.nix-ai-tools.packages.${pkgs.system}.claude-code;
    };
  };
}
