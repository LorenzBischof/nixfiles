{
  self,
  config,
  pkgs,
  pkgs-citrix-workspace,
  lib,
  stylix,
  inputs,
  ...
}:
let
  # This is required, so that app_id is set and we can create Sway window rules
  logseqWithDesktopName = pkgs.logseq.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      packageJson="$out/share/logseq/resources/app/package.json"
      ${lib.getExe pkgs.jq} '.desktopName = "Logseq"' "$packageJson" > package.json.tmp
      mv package.json.tmp "$packageJson"
    '';
  });
in
{
  imports = [
    ../../../modules/home
    inputs.nix-secrets.homeManagerModule
  ];

  my.programs.firefox.enable = true;
  my.programs.git.enable = true;
  my.profiles.ai.enable = true;

  systemd.user.services.kanshi = {
    Service.ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
    Unit.X-Reload-Triggers = [ "${config.xdg.configFile."kanshi/config".source}" ];
  };

  services.kanshi = {
    enable = true;
    systemdTarget = "sway-session.target";
    settings = [
      {
        profile.name = "undocked";
        profile.outputs = [
          {
            criteria = "eDP-1";
          }
        ];
      }
      {
        profile.outputs = [
          {
            criteria = "eDP-1";
            mode = "2880x1920@120Hz";
            position = "2822,2037";
            scale = 2.0;
          }
          {
            criteria = "LG Electronics LG HDR 4K 0x00021724";
            mode = "3840x2160@60Hz";
            position = "2585,957";
            scale = 2.0;
          }
        ];
      }
      {
        profile.outputs = [
          {
            criteria = "Dell Inc. DELL U3421WE DKDB753";
            mode = "3440x1440@59Hz";
            position = "2121,1321";
            scale = 1.0;
          }
          {
            criteria = "eDP-1";
            mode = "2880x1920@120Hz";
            position = "3140,2761";
            scale = 2.0;
          }
        ];
      }
      {
        profile.outputs = [
          {
            criteria = "eDP-1";
            mode = "2880x1920@120Hz";
            position = "591,1440";
            scale = 2.0;
          }
          {
            criteria = "Lenovo Group Limited P27q-30 V30BGZ9H";
            mode = "2560x1440";
            position = "0,0";
            scale = 1.0;
          }
        ];
      }
      {
        profile.outputs = [
          {
            criteria = "eDP-1";
            mode = "2880x1920";
            position = "568,1080";
            scale = 2.0;
          }
          {
            criteria = "Dell Inc. DELL U4025QW 4MQ6FP3";
            mode = "5120x2160";
            position = "0,0";
            scale = 2.0;
          }
        ];
      }
      {
        profile.outputs = [
          {
            criteria = "eDP-1";
            mode = "2880x1920";
            position = "240,1080";
            scale = 2.0;
          }
          {
            criteria = "Dell Inc. DELL U2720Q 6YSSY13";
            mode = "3840x2160";
            position = "0,0";
            scale = 2.0;
          }
        ];
      }
    ];
  };

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    github-cli
    mullvad-browser
    keepassxc
    gnumake
    logseqWithDesktopName
    pavucontrol
    #jellyfin-media-player   # insecure because of qtwebengine-5.15.19
    xournalpp
    simple-scan
    mpv
    gramps
    imv
    wl-mirror
    sshfs
    devbox
    yubikey-manager
    google-chrome

    # Required so that Logseq can open links
    # There is probably a NixOS option for this...
    xdg-utils

    # fonts
    font-awesome
    nerd-fonts.dejavu-sans-mono
    (writeShellApplication {
      name = "wfica";
      runtimeInputs = [
        pkgs-citrix-workspace.citrix_workspace
      ];
      text = ''
        sed -i 's/TWIMode=On/TWIMode=Off/' "$1"
        nohup systemd-inhibit --what=sleep --mode=block --why="Citrix session" wfica "$1" >/dev/null 2>&1 &
      '';
    })
  ];

  systemd.user.startServices = true;
  systemd.user.tmpfiles.rules = [
    "d %h/.ssh/controlmasters 0700 - - -"
  ];

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
      enableDefaultConfig = false;
      settings = {
        "*" = {
          IdentitiesOnly = true;
        };
        "gitlab.com" = {
          # SSH connection multiplexing to avoid multiple yubikey touches (e.g. for git-lfs)
          # https://github.com/git-lfs/git-lfs/issues/5784
          ControlMaster = "auto";
          ControlPersist = "5s";
          ControlPath = "~/.ssh/controlmasters/%C";
        };
        "scanner" = {
          HostName = "192.168.0.157";
          User = "pi";
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "ha" = {
          HostName = "192.168.0.103";
          User = "hassio";
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "rpi3" = {
          HostName = "192.168.0.108";
          User = "nixos";
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "Match originalhost nas exec \"tailscale status\"" = lib.hm.dag.entryBefore [ "nas" ] {
          HostName = "nas";
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "nas" = {
          HostName = "192.168.0.124";
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "nas-unlock" = {
          HostName = "192.168.0.124";
          User = "root";
          Port = 2222;
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "nas.local" = {
          HostName = "192.168.1.2";
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
        "vps" = {
          IdentityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
      };
    };
  };

  programs.zsh.initContent = lib.mkAfter ''
    if [[ -r /run/agenix/github-token ]]; then
      export GH_TOKEN=$(grep -oP '(?<=github\.com=)\S+' /run/agenix/github-token)
    fi
  '';

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
