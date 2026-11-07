{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = lib.mkIf config.my.profiles.ai.enable {
    # nixpkgs' playwright-core includes the agent CLI and its matching skills.
    home.packages = [
      (pkgs.writeShellApplication {
        name = "playwright-cli";
        runtimeInputs = [ pkgs.nodejs ];
        text = ''
          exec node ${pkgs.playwright}/cli.js cli "$@"
        '';
      })
    ];

    home.file.".playwright/cli.config.json".text = builtins.toJSON {
      browser.launchOptions.executablePath = lib.getExe pkgs.google-chrome;
    };
  };
}
