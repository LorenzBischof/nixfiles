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
  # logseq's build freezes on current nixpkgs (NixOS/nixpkgs#535206), and it isn't
  # cached upstream because its electron_39 is EOL. Pin to the revision right
  # before electron_39 was marked EOL: there logseq still builds and is cached on
  # cache.nixos.org (so it's substituted, never built). A bare fetchTarball (not a
  # flake input) keeps it out of Dependabot's reach.
  pkgs-logseq = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/ec0c722e017dfccbb2f66a8aafbe003320266d33.tar.gz";
    sha256 = "0jws2i94asr1yish76799gmyw51dj98n8badq3snc8prifmsd3a5";
  }) { inherit (pkgs.stdenv.hostPlatform) system; };

  # The desktopName sets the Wayland app_id so we can target Logseq in Sway window
  # rules. We must NOT use overrideAttrs for this: that changes the derivation,
  # busting the cache and re-triggering the build that freezes upstream. Instead,
  # copy the substituted output and patch the one file in place (a cheap local
  # copy, no rebuild).
  logseqWithDesktopName =
    pkgs.runCommand pkgs-logseq.logseq.name { inherit (pkgs-logseq.logseq) meta; }
      ''
        cp -r ${pkgs-logseq.logseq} $out
        chmod -R u+w $out

        packageJson="$out/share/logseq/resources/app/package.json"
        ${lib.getExe pkgs.jq} '.desktopName = "Logseq"' "$packageJson" > "$packageJson.tmp"
        mv "$packageJson.tmp" "$packageJson"

        # The copied wrapper still points electron's --app flag at the original
        # store path; repoint it at our patched copy.
        substituteInPlace $out/bin/logseq --replace-fail "${pkgs-logseq.logseq}" "$out"
      '';
in
{
  imports = [
    ../../../modules/home
    inputs.nix-secrets.homeManagerModule
  ];

  my.programs.firefox.enable = true;
  my.programs.git.enable = true;
  my.profiles.ai.enable = true;

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

    # home-manager now warns when home.pointerCursor.{name,size,package} (set by
    # stylix's `cursor` option) are relied upon to implicitly enable cursor config
    # generation; explicit enable silences that without changing behavior.
    # Upstream fix pending: https://github.com/nix-community/stylix/pull/2407
    pointerCursor.enable = true;

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
