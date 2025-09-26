{
  config,
  pkgs,
  lib,
  ...
}:
{
  home.packages = with pkgs; [
    aider-chat
  ];

  home.sessionVariables = {
    AIDER_ENV_FILE = "/run/agenix/aider-chat-env";
    AIDER_DARK_MODE = "true";
    AIDER_AUTO_COMMITS = "false";
  };
}
