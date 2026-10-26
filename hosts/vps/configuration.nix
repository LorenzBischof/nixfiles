{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    #./n8n.nix
    ./cooklang.nix
    ./galaxus.nix
    ./mcp.nix
    ../../modules/nixos
  ];
  nixpkgs.config.allowUnfree = true;

  my.services.nixpkgs-age-monitor.enable = true;

  # Always-on with a stable tailnet address, so the nas scrapes it (pull).
  my.monitoring.client.enable = true;

  my.system.autoUpgrade = {
    enable = true;
    dates = "hourly";
    flake = "github:LorenzBischof/nixfiles";
  };

  my.homelab = {
    domain = secrets.vps-domain;
    nginx = {
      enable = true;
      acme = {
        enable = true;
        dnsProvider = "cloudflare";
        environmentFile = config.age.secrets.cloudflare-token.path;
      };
    };
  };
  services.nginx.defaultListenAddresses = [ "100.91.84.39" ];

  boot = {
    # nginx binds the tailnet address set above, which only exists while
    # tailscale0 is up. A switch that restarts tailscaled briefly drops it, and
    # the nginx reload then fails its config test on bind(). Allowing a
    # non-local bind keeps the reload working regardless.
    kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

    loader = {
      systemd-boot.enable = true;
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };
  };

  systemd.targets.multi-user.enable = true;

  networking.hostName = "vps";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Zurich";
  i18n.defaultLocale = "en_US.UTF-8";

  users = {
    mutableUsers = false;
    users.lbischof = {
      isNormalUser = true;
      extraGroups = [
        "networkmanager"
        "wheel"
      ];
      openssh.authorizedKeys.keys = [
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHkFqdhSF5DYceP6AJDgBj2PihSSht6LRfTk39llKX8uAAAAC3NzaDpob21lbGFi"
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIB/zgMFamMRd57dXMuU7E4NHP/gHrybWrGi55m8D8nrKAAAAC3NzaDpob21lbGFi"
      ];
    };
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    curl
    git
    vim
    wget
  ];

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      # PasswordAuthentication alone is not enough: keyboard-interactive goes
      # through PAM and accepts the Unix password anyway. Matters now that
      # lbischof has a declared password instead of a locked account.
      KbdInteractiveAuthentication = false;
    };
  };

  services.tailscale = {
    enable = true;
    # Accept inbound WireGuard so peers can establish a direct path instead of
    # falling back to a DERP relay, which throttles cache pulls to ~1 MB/s.
    # This exposes no service: the port only answers a valid handshake from a
    # key already in the tailnet and silently drops anything else.
    # The Oracle VCN security list has to allow UDP 41641 too.
    openFirewall = true;
  };

  # Disable autologin.
  services.getty.autologinUser = null;

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [ 22 ];
  # networking.firewall.allowedUDPPorts = [ ... ];

  # Disable documentation for minimal install.
  documentation.enable = false;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Did you read the comment?
}
