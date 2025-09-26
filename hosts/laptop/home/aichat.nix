{
  config,
  pkgs,
  lib,
  ...
}:

let
  aichatConfig = pkgs.writeText "aichat.yaml" (
    builtins.toJSON {
      model = "claude:claude-3-5-sonnet-latest";
      #platform = "claude";
      clients = [
        {
          type = "claude";
        }
      ];
    }
  );
in
{
  home.packages = with pkgs; [
    aichat
  ];

  home.sessionVariables = {
    AICHAT_ENV_FILE = "/run/agenix/aichat-env";
    AICHAT_CONFIG_FILE = "${aichatConfig}";
  };
}
