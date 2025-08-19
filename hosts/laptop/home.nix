{
  self,
  config,
  pkgs,
  lib,
  stylix,
  inputs,
  ...
}:
{
  imports = [
    ./home-manager/alacritty
    ./home-manager/dunst
    ./home-manager/foot.nix
    ./home-manager/sway
    ./home-manager/i3
    ./home-manager/scripts
    ./home-manager/aider-chat.nix
    ./home-manager/aichat.nix
    ../../modules/home-manager/git
    ../../modules/home-manager/shell
    inputs.nix-secrets.homeManagerModule
    inputs.numen.homeManagerModule
  ];

  services.numen = {
    enable = true;
    xkbLayout = "de";
    xkbVariant = "adnw";
    subtitles.enable = true;
    updateCommand = pkgs.writeShellApplication {
      name = "reload-i3status";
      text = "pkill -SIGRTMIN+4 i3status-rs";
    };
  };

  services.safeeyes = {
    # https://github.com/NixOS/nixpkgs/issues/242664
    package = pkgs.callPackage ../../packages/safeeyes.nix { };
    enable = true;
  };

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages =
    with inputs.nix-ai-tools.packages.${pkgs.system};
    [
      opencode
    ]
    ++ (with pkgs; [
      mullvad-browser
      firefox
      keepassxc
      gnumake
      logseq
      pavucontrol
      jellyfin-media-player
      xournalpp
      simple-scan
      mpv
      gramps
      imv
      wl-mirror
      sshfs

      # Required so that Logseq can open links
      # There is probably a NixOS option for this...
      xdg-utils

      # fonts
      font-awesome
      nerd-fonts.dejavu-sans-mono
      citrix_workspace
    ]);

  systemd.user.startServices = true;
  gtk = {
    enable = true;
    theme = {
      package = pkgs.gnome-themes-extra;
      name = "Adwaita-dark";
    };
  };

  fonts.fontconfig.enable = true;
  programs = {
    obs-studio.enable = true;
    go.enable = true;
    thunderbird = {
      enable = true;
      profiles.default = {
        isDefault = true;
      };
    };
    ssh = {
      enable = true;
      matchBlocks = {
        "*" = {
          identitiesOnly = true;
        };
        "scanner" = {
          hostname = "192.168.0.157";
          user = "pi";
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "ha" = {
          hostname = "192.168.0.102";
          user = "hassio";
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "rpi3" = {
          hostname = "192.168.0.108";
          user = "nixos";
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "nas-tailscale" = lib.hm.dag.entryBefore [ "nas" ] {
          match = ''originalhost nas exec "tailscale status"'';
          hostname = "100.102.187.46";
          user = "lbischof";
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "nas" = {
          hostname = "192.168.0.124";
          user = "lbischof";
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "nas-unlock" = {
          hostname = "192.168.0.124";
          user = "root";
          port = 2222;
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "nas.local" = {
          hostname = "192.168.1.2";
          user = "lbischof";
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "oracle" = {
          hostname = "140.238.171.222";
          user = "lbischof";
          identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
      };
    };
  };

  services.etesync-dav.enable = true;

  home = {
    file.".config/yubikey-touch-detector/service.conf".text = ''
      YUBIKEY_TOUCH_DETECTOR_LIBNOTIFY=true
    '';

    # Home Manager needs a bit of information about you and the paths it should
    # manage.
    username = "lbischof";
    homeDirectory = "/home/lbischof";

    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    stateVersion = "23.05"; # Please read the comment before changing.
  };
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
