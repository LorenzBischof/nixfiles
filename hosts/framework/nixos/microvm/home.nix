{
  config,
  pkgs,
  lib,
  vmName ? "nixfiles",
  ...
}:

{
  imports = [
    ../../../../modules/home/ai
  ];

  my.profiles.ai.enable = true;
  my.profiles.ai.codexArgs = [
    "--dangerously-bypass-approvals-and-sandbox"
    "-c"
    "tui.animations=false"
  ];
  my.profiles.ai.agentsFile = ../AGENTS.microvm.md;

  home.username = "microvm";
  home.homeDirectory = "/home/microvm";

  home.file.".codex/auth.json".source =
    config.lib.file.mkOutOfStoreSymlink "/run/host-credentials/codex/auth.json";

  home.packages = [ pkgs.github-cli ];

  programs.zsh = {
    enable = true;
    initContent = lib.mkAfter ''
      if [[ -r /run/host-credentials/github-token/github-token ]]; then
        export GH_TOKEN=$(grep -oP '(?<=github\.com=)\S+' /run/host-credentials/github-token/github-token)
      fi
    '';
    history = {
      size = 4000;
      save = 10000000;
      ignoreDups = true;
      share = false;
      append = true;
    };
  };

  programs.git.enable = true;
  programs.jujutsu.enable = true;

  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
}
