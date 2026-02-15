{
  config,
  pkgs,
  inputs,
  lib,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  umapDomain = "umap.${domain}";

  # Customized Python with Django 5 + GDAL (same as umap package)
  python = pkgs.python3.override {
    self = python;
    packageOverrides = final: prev: {
      django = prev.django_5.override { withGdal = true; };
    };
  };
in
{
  imports = [
    "${inputs.nixpkgs-umap}/nixos/modules/services/web-apps/umap.nix"
  ];

  # Disable NixOS manual generation to avoid umap module doc issues
  documentation.nixos.enable = false;

  services.umap = {
    enable = true;
    package = inputs.nixpkgs-umap.legacyPackages.x86_64-linux.umap;
    settings.SITE_URL = "https://${umapDomain}";
  };

  services.nginx.virtualHosts."${umapDomain}".useACMEHost = domain;

  my.homelab.dashboard.Services.UMap.href = "https://${umapDomain}";

  services.restic.backups.daily.paths = [
    config.services.umap.stateDir
  ];
}
