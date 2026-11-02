# Raspberry Pi 3 (aarch64, 1 GB RAM, SD card).
#
# Deliberately standalone for now: ../../modules/nixos needs agenix secrets
# (the nix-daemon cache credentials) and a nix-secrets host module, which this
# board does not have yet. Bring them in once the basics are proven.
#
# The SD-image module stays imported for the running system too, so the image
# and later `nixos-rebuild --target-host` deploys share one configuration (its
# filesystems are mounted by label). It also pulls in the installer's
# profiles/base.nix and enableAllHardware, which cost closure size; trim those
# once the board boots.
#
# Never evaluate on the Pi itself: 1 GB is not enough to evaluate this flake.
# Build on vps (native aarch64) or framework (binfmt) and push:
#   nixos-rebuild switch --flake .#rpi3 --target-host lbischof@rpi3 --build-host vps --sudo
{
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "rpi3";
  time.timeZone = "Europe/Zurich";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.lbischof = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHkFqdhSF5DYceP6AJDgBj2PihSSht6LRfTk39llKX8uAAAAC3NzaDpob21lbGFi"
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIB/zgMFamMRd57dXMuU7E4NHP/gHrybWrGi55m8D8nrKAAAAC3NzaDpob21lbGFi"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  # wheel is root already through passwordless sudo, so trusting it costs
  # nothing; deploys copy unsigned paths built elsewhere in as lbischof.
  nix.settings.trusted-users = [ "@wheel" ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  environment.systemPackages = [ pkgs.git ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Low RAM: compressed swap in memory, never a swapfile on the card.
  zramSwap.enable = true;
  documentation.enable = false;

  # SD card space: few generations, collected often, plus an emergency GC when
  # free space runs low during a copy.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
  };
  nix.settings.min-free = 1024 * 1024 * 1024;
  nix.settings.max-free = 3 * 1024 * 1024 * 1024;
  boot.loader.generic-extlinux-compatible.configurationLimit = 3;

  # SD card wear: keep the steady trickle of small writes off the card.
  services.journald.settings.Journal = {
    Storage = "volatile";
    RuntimeMaxUse = "32M";
  };
  fileSystems."/".options = [ "noatime" ];

  # Compressing the image under binfmt emulation takes ages.
  sdImage.compressImage = false;

  system.stateVersion = "26.11";
}
