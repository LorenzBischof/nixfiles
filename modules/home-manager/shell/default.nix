{
  config,
  pkgs,
  lib,
  ...
}:
{
  home.packages = with pkgs; [
    devenv
    kubectl
    ripgrep
    dtrx
    nvim-pkg
  ];
  programs = {
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config.global = {
        hide_env_diff = true;
      };
    };
    starship = {
      enable = true;
      enableZshIntegration = true;
      settings = {
        add_newline = false;
        format = "$character";
        right_format = "$all";
        aws = {
          disabled = true;
        };
      };
    };
    zsh = {
      enable = true;
      shellAliases = {
        "k" = "kubectl";
        "tt" = "jj";
      };
      initExtra = ''
        source ~/.zshrc-extra
      '';
    };
    eza = {
      enable = true;
      git = true;
      icons = "auto";
    };
    fzf = {
      enable = true;
      defaultCommand = "fd --type f";
      changeDirWidgetCommand = "fd --type d";
      fileWidgetCommand = "fd --type f";
    };
    fd.enable = true;
    jq.enable = true;
    tmux = {
      enable = true;
      historyLimit = 100000;
      terminal = "screen-256color";
      mouse = true;
      extraConfig = ''
        unbind -n MouseDrag1Pane
      '';
    };
  };

  home.sessionVariables = {
    EDITOR = "nvim";
    PAGER = "less -FRX";
  };

  home.file = {
    ".zshrc-extra".source = ./initextra;
  };

}
