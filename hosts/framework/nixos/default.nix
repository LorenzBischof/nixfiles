# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running `nixos-help`).

{
  config,
  lib,
  pkgs,
  secrets,
  inputs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./ai.nix
    ./autoupgrade.nix
    ./monitoring.nix
    ./disko.nix
    ./low-battery-power-button-led.nix
    ./lid-closed-led.nix
    ./vm-autosleep.nix
    ./power.nix
  ];

  my.services = {
    detect-reboot-required.enable = true;
    detect-syncthing-conflicts.enable = true;
    nixpkgs-age-monitor.enable = true;
  };
  # upower automatically hibernates when battery is low
  services.upower = {
    enable = true;
    noPollBatteries = true;
  };

  services.tailscale.enable = true;

  boot = {
    consoleLogLevel = 3;
    kernelParams = [ "quiet" ];

    # KVM halt-polling busy-spins an idle vCPU before actually halting it: a
    # latency-for-power trade that costs ~2.5% of a host core per idle vCPU.
    # The local VM guests are its worst case: vCPUs that are permanently idle
    # but never quiet, because their workload heartbeats forever. Measured as
    # an alternating A/B (200000/0/200000/0, 45s phases):
    # 0.800 cores with polling on vs 0.694 with it off, 13% off for free.
    # Nothing in the guests cares about interrupt latency, so buy the battery.
    extraModprobeConfig = "options kvm halt_poll_ns=0";

    plymouth = {
      enable = true;
    };
    # 7.3 oopses in mt7925e_mac_reset (napi_disable on the never-allocated WM2
    # queue) when hibernation thaws devices, so the image is never written.
    # Fixed upstream by c182bfe944eb; back to _latest once a 7.3.y/7.4 has it.
    kernelPackages = pkgs.linuxPackages_7_2;
    loader = {
      timeout = 0;
      systemd-boot.enable = false; # disable when using lanzaboote
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };
    binfmt.emulatedSystems = [ "aarch64-linux" ];
  };

  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
  };

  # The tpm2 module ships the unit but never enables it, so the
  # tpm2-measure-pcr=yes extend in disko.nix fails with ENOENT.
  boot.initrd.systemd.sockets.systemd-pcrextend.wantedBy = [ "sockets.target" ];

  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  systemd.sleep.settings.Sleep = {
    HibernateDelaySec = "2h";
    SuspendState = "mem";
    HibernateOnACPower = "no";
  };
  environment.etc."systemd/system-sleep/drop-caches-on-hibernate".source =
    pkgs.writeShellScript "drop-caches-on-hibernate" ''
      if [ "$1" = "pre" ] && [ "$SYSTEMD_SLEEP_ACTION" = "hibernate" ]; then
        logger -t drop-caches-on-hibernate "syncing before hibernate"
        ${pkgs.coreutils}/bin/sync
        echo 3 > /proc/sys/vm/drop_caches
      fi
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

  # The Talos cluster ingress VIP. vm-autosleep.nix needs the same address to keep
  # it wakeable while the guests are paused, and a VIP resolving to one address
  # while only another is wakeable is silent -- *.talos simply stops working -- so
  # both read this one binding.
  _module.args.talosIngressVip = "10.69.0.200";

  # Resolve *.talos to that VIP via NM's dnsmasq plugin. Don't switch this to
  # systemd-resolved with a global DNS/Domains override: that hijacks the global
  # resolver and breaks Tailscale MagicDNS.
  networking.networkmanager.dns = "dnsmasq";
  environment.etc."NetworkManager/dnsmasq.d/talos.conf".text = ''
    address=/talos/${config._module.args.talosIngressVip}
  '';

  # Temporary fix for Swaylock issue TODO: what issue?
  security.pam.services.swaylock = { };

  # Containers
  virtualisation = {
    docker.enable = true;
    libvirtd = {
      enable = true;
      # The default "suspend" saves guests to disk on host shutdown and restores
      # them at boot; the restored Talos VMs came back with a frozen clock.
      onShutdown = "shutdown";
    };
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

    # The EC's built-in fan curve lets the chassis get hot before spinning up.
    # Strategies ship with the package; "medium" starts ramping at 40°C.
    fw-fanctrl = {
      enable = true;
      config = {
        defaultStrategy = "medium";
        strategyOnDischarging = "lazy";
      };
    };
  };

  services.thermald.enable = true;
  #services.auto-cpufreq.enable = true;

  security.polkit.enable = true;

  # Sound
  services.pipewire = {
    enable = true;
    pulse.enable = true;
    # The ALC285 emits ~1s of clipped audio when it resumes from D3, so
    # dictation loses its first word. WirePlumber suspends the mic after 5s by
    # default; a 10 minute grace keeps a dictation session warm and still
    # suspends an idle mic, unlike pinning the codec in D0 permanently.
    wireplumber.extraConfig."51-mic-suspend-grace" = {
      "monitor.alsa.rules" = [
        {
          matches = [ { "node.name" = "alsa_input.pci-0000_c1_00.6.analog-stereo"; } ];
          actions.update-props."session.suspend-timeout-seconds" = 600;
        }
      ];
    };
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
      # Writing a wifi profile needs polkit's settings.modify.system, which
      # only this group gets: no polkit agent runs in the sway session to ask
      # for a password. Without it the bar's wifi menu silently cannot join or
      # forget a network.
      "networkmanager"
      "i2c"
      "scanner"
      "libvirtd"
      "docker"
      "kvm"
    ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    git
    home-manager
    ddcutil
  ];

  console.keyMap = "adnw";

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

  nixpkgs.overlays = [
    inputs.neovim-config.overlays.default
  ];

  # https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = false;

  system.stateVersion = "23.05"; # Did you read the comment?
  nixpkgs.config.allowUnfree = true;
}
