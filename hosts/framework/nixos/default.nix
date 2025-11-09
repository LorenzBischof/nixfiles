# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running `nixos-help`).

{
  config,
  pkgs,
  secrets,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./autoupgrade.nix
    ./disko.nix
  ];

  services.ollama.enable = true;
  services.open-webui.enable = true;

  my.services = {
    detect-reboot-required.enable = true;
    detect-syncthing-conflicts.enable = true;
    nixpkgs-age-monitor = {
      enable = true;
      alertThresholdDays = 7;
      ntfyTopic = secrets.ntfy-alertmanager;
    };
  };
  # upower automatically hibernates when battery is low
  services.upower = {
    enable = true;
    noPollBatteries = true;
  };

  stylix = {
    enable = true;
    #image = ../home/sway/wallpaper_cropped_1.png;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/eighties.yaml";
    autoEnable = true;
    fonts.sizes = {
      popups = 18;
      desktop = 14;
    };
    cursor = {
      size = 28;
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
  };

  services.tailscale.enable = true;

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    loader = {
      systemd-boot.enable = true;
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };
    initrd.systemd.enable = true;
    binfmt.emulatedSystems = [ "aarch64-linux" ];
  };

  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  systemd.sleep.extraConfig = ''
    HibernateDelaySec=2h
    SuspendState=mem
    HibernateOnACPower=no
  '';
  # Disable Bluetooth as wakeup source, because it prevents automatic hibernation
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="btusb", ATTR{power/wakeup}="disabled"
  '';
  services.logind.settings.Login = {
    HandlePowerKey = "suspend-then-hibernate";
    HandleLidSwitch = "suspend-then-hibernate";
  };

  networking = {
    hostName = "framework";
    networkmanager.enable = true;
  };

  # Temporary fix for Swaylock issue TODO: what issue?
  security.pam.services.swaylock = { };

  # Containers
  virtualisation = {
    docker.enable = true;
    libvirtd.enable = true;
  };

  hardware = {
    bluetooth.enable = true;
    sane.enable = true;
    # For some reason the avahi options above do not work
    sane.netConf = "192.168.0.157";

    brillo.enable = true;

    i2c.enable = true;
    # Required for Sway
    graphics.enable = true;

    opentabletdriver.enable = true;
  };

  services.thermald.enable = true;
  #services.auto-cpufreq.enable = true;

  security.polkit.enable = true;

  # Sound
  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };
  # Set a higher priority, so that the headset port activates automatically
  #environment.etc."alsa-card-profile/mixer/paths/analog-input-headset-mic.conf".source =
  #  ./analog-input-headset-mic.conf;
  programs.noisetorch.enable = true;

  services.syncthing = {
    enable = true;
    user = "lbischof";
    dataDir = "/home/lbischof";
    openDefaultPorts = true;
  };

  users.mutableUsers = false;
  users.users.lbischof = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "video"
      "keyd"
      "i2c"
      "scanner"
      "adbUsers"
      "libvirtd"
      "docker"
    ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    git
    home-manager
    ddcutil
  ];

  services.xserver = {
    enable = true;
    xkb = {
      layout = "de";
      variant = "adnw";
    };
  };
  console.useXkbConfig = true;

  services.libinput.enable = true;
  # services.xserver.desktopManager.xterm.enable = false;
  programs.sway.enable = true;

  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --xsessions ${config.services.displayManager.sessionData.desktops}/share/xsessions --sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions --remember --remember-user-session";
      user = "greeter";
    };
  };

  programs = {
    nix-index-database.comma.enable = true;
    command-not-found.enable = false;
    zsh.enable = true;
    # Required for Stylix
    dconf.enable = true;
    yubikey-touch-detector.enable = true;
    adb.enable = true;
    virt-manager.enable = true;
    nix-ld.enable = true;
  };

  # xdg-desktop-portal works by exposing a series of D-Bus interfaces
  # known as portals under a well-known name
  # (org.freedesktop.portal.Desktop) and object path
  # (/org/freedesktop/portal/desktop).
  # The portal interfaces include APIs for file access, opening URIs,
  # printing and others.
  services.dbus.enable = true;
  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-gtk
    ];
    # TODO: Figure out if we can use configPackages
    config.common.default = "*";
  };

  services = {
    hardware.bolt.enable = true;

    # Firmware updater
    fwupd.enable = true;
  };

  # https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = false;

  system.stateVersion = "23.05"; # Did you read the comment?
}
