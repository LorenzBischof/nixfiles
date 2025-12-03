{
  self,
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.programs.firefox;
in
{
  options.my.programs.firefox.enable = lib.mkEnableOption "firefox";

  config = lib.mkIf cfg.enable {
    # Currently using a theme
    stylix.targets.firefox.enable = false;
    programs.firefox = {
      enable = true;

      policies = {
        DisableTelemetry = true;
        DisableFirefoxAccounts = true;
        PasswordManagerEnabled = false;
        OfferToSaveLogins = false;
        DisableFirefoxStudies = true;
        TranslateEnabled = false;
      };
      profiles.default = {
        id = 0;
        name = "default";
        isDefault = true;
        containersForce = true;
        search = {
          force = true;
          default = "ddg";
          engines = {
            "Nix Packages" = {
              urls = [
                {
                  template = "https://search.nixos.org/packages";
                  params = [
                    {
                      name = "channel";
                      value = "unstable";
                    }
                    {
                      name = "query";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = "https://search.nixos.org/favicon.png";
              definedAliases = [ "@np" ];
            };
            "NixOS Options" = {
              urls = [
                {
                  template = "https://search.nixos.org/options";
                  params = [
                    {
                      name = "channel";
                      value = "unstable";
                    }
                    {
                      name = "query";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = "https://search.nixos.org/favicon.png";
              definedAliases = [ "@no" ];
            };
            "Home Manager Options" = {
              urls = [
                {
                  template = "https://home-manager-options.extranix.com";
                  params = [
                    {
                      name = "release";
                      value = "master";
                    }
                    {
                      name = "query";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = "https://search.nixos.org/favicon.png";
              definedAliases = [ "@nh" ];
            };
            "NixOS Wiki" = {
              urls = [
                {
                  template = "https://wiki.nixos.org/w/index.php";
                  params = [
                    {
                      name = "fulltext";
                      value = "1";
                    }
                    {
                      name = "search";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = "https://search.nixos.org/favicon.png";
              definedAliases = [ "@nw" ];
            };
            "Nixpkgs Issues" = {
              urls = [
                {
                  template = "https://github.com/NixOS/nixpkgs/issues";
                  params = [
                    {
                      name = "q";
                      value = "{searchTerms}";
                    }
                  ];
                }
              ];
              icon = "https://search.nixos.org/favicon.png";
              definedAliases = [ "@ni" ];
            };
            "Nix Code" = {
              urls = [
                {
                  template = "https://github.com/search?q=test+language%3ANix&type=Repositories&ref=advsearch&l=Nix&l=";
                  params = [
                    {
                      name = "q";
                      value = "{searchTerms} language:Nix";
                    }
                    {
                      name = "type";
                      value = "code";
                    }
                  ];
                }
              ];
              icon = "https://search.nixos.org/favicon.png";
              definedAliases = [ "@nc" ];
            };
          };
        };
        settings = {
          "browser.newtabpage.activity-stream.feeds.topsites" = false;
          "browser.aboutConfig.showWarning" = false;
          "browser.fullscreen.autohide" = false;
        };
      };
    };
  };
}
