{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  asustor-platform-driver = config.boot.kernelPackages.callPackage ./asustor-platform-driver.nix { };
in
{
  imports = [
    ./hardware-configuration.nix
    ./monitoring.nix
    ./homelab.nix
    ./nixhome.nix
    ./authelia.nix
    ./backup.nix
    ./paperless.nix
    ./vaultwarden.nix
    ./syncthing.nix
    ./media.nix
    ./photos.nix
    ./offline-backup.nix
    ./scrutiny.nix
    ./open-webui.nix
    ./homeassistant.nix
    ./mealie.nix
    ./hedgedoc.nix
    ./outline.nix
    ../../modules/nixos/common.nix
  ];

  homelab.domain = lib.mkDefault secrets.prod-domain;

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    extraModulePackages = [ asustor-platform-driver ];
    kernelModules = [
      "r8169"
      "asustor_gpio_it87"
      "asustor_it87"
    ];
    initrd = {
      kernelModules = config.boot.kernelModules;
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          hostKeys = [ "/boot/initrd-host-key" ];
          authorizedKeys = config.users.users.lbischof.openssh.authorizedKeys.keys;
        };
        postCommands = ''
          # blink faster
          echo 0 | tee /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1_blink_freq
          echo "zfs load-key -a; killall zfs" >> /root/.profile
        '';
      };
    };
  };

  systemd.services.asustor-leds-control = {
    description = "Control Asustor NAS LEDs";
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      # reduce brightness
      echo 200 | tee /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/pwm3
      # stop blinking
      echo 0 | tee /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1_blink
    '';
    wantedBy = [
      "multi-user.target"
      "suspend.target"
    ];
    after = [ "suspend.target" ];
  };

  systemd.services.scheduled-suspend = {
    description = "Schedule system suspend at night";
    enable = true;
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      # use `systemctl` instead of `-m mem`, because of better integration with systemd
      # this allows scripts to be run when waking up, by using the suspend.target
      rtcwake -m no -t $(date -d 'tomorrow 8:00:00' '+%s') && systemctl suspend
    '';
    path = [ pkgs.util-linux ];
    startAt = "21:00";
  };

  networking.hostName = "nas";
  networking.hostId = "115d4c0d";

  services.zfs.autoScrub.enable = true;

  networking.useDHCP = true;

  i18n.defaultLocale = "en_GB.UTF-8";

  console.keyMap = "sg";

  users.users.lbischof = {
    isNormalUser = true;
    description = "lbischof";
    extraGroups = [
      "networkmanager"
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIDSKZEtyhueGqUow/G2ewR5TuccLqhrgwWd5VUnd6ImqAAAAC3NzaDpob21lbGFi"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    vim
    lm_sensors
  ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.age.secrets.tailscale-preauth.path;
    extraUpFlags = [
      "--accept-dns=false"
      "--advertise-routes=192.168.0.0/24"
    ];
  };

  hardware.fancontrol =
    let
      fan = "/sys/devices/platform/asustor_it87.2608/hwmon/hwmon[[:print:]]*";
    in
    {
      enable = true;
      config = ''
        INTERVAL=10
        FCTEMPS=${fan}/pwm1=/sys/devices/platform/coretemp.0/hwmon/hwmon[[:print:]]*/temp2_input
        FCFANS=${fan}/pwm1=${fan}/fan1_input
        MINTEMP=${fan}/pwm1=60
        MAXTEMP=${fan}/pwm1=110
        MINSTART=${fan}/pwm1=30
        MINSTOP=${fan}/pwm1=50
        MINPWM=${fan}/pwm1=50
        MAXPWM=255
        AVERAGE=5
      '';
    };

  virtualisation.vmVariant = {
    homelab.domain = secrets.test-domain;
    security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";
    services.restic.backups.daily.repositoryFile = pkgs.writeText "restic-repo" "/srv/restic-repo";

    virtualisation = {
      memorySize = 2048;
      cores = 3;
    };

    virtualisation.qemu.networkingOptions = [
      "-device virtio-net-pci,netdev=net0"
      "-netdev tap,id=net0,br=br0,helper=/run/wrappers/bin/qemu-bridge-helper"
    ];

    #    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;

    virtualisation.useDefaultFilesystems = false;
    virtualisation.fileSystems."/" = {
      device = "tank/root";
      fsType = "zfs";
    };

    # These commands are run on every boot, but fail if the zpool already exists
    boot.initrd.postDeviceCommands = ''
      zpool create -O mountpoint=none -O atime=off -O xattr=sa -O acltype=posixacl -o ashift=12 tank /dev/vda
      zfs create -o mountpoint=legacy tank/root
      zfs snapshot tank/root@blank
    '';

    # Make sure the password is always correctly set
    users.mutableUsers = false;
    users.users.lbischof.password = "test";

    # Set a static IP in the VM
    # eth0 is the SLIRP interface (not sure why it still exists)
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = "192.168.1.2";
        prefixLength = 24;
      }
    ];
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?

}
