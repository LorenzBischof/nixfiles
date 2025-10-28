{
  modulesPath,
  lib,
  self,
  nixpkgs,
  pkgs,
  config,
  ...
}:
{
  imports = [
    # This should not be required when using `nixos-rebuild build-image --image-variant iso-installer` (?)
    # Already the default in `nixpkgs/nixos/modules/image/images.nix`
    # However I receive assertion errors when running `nix flake check`.
    "${toString modulesPath}/installer/cd-dvd/installation-cd-base.nix"
  ];

  config = {
    services.xserver = {
      enable = true;
      xkb = {
        layout = "de";
        variant = "adnw";
      };
    };
    console.useXkbConfig = true;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.PermitRootLogin = lib.mkForce "without-password";
    };

    users.users.nixos.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKbzinQvw6VH6UeR3QcdU4tnzzgI9nWWWtqJd7SHN6rG"
    ];

    image.modules.iso-installer = {
      isoImage.squashfsCompression = "zstd -Xcompression-level 3";
    };
  };
}
