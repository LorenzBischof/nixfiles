{
  config,
  pkgs,
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
  services.umap = {
    enable = true;
    settings = {
      SITE_URL = "https://${umapDomain}";
    };
  };

  services.nginx.virtualHosts."${umapDomain}".useACMEHost = domain;

  my.homelab.dashboard.Services.UMap.href = "https://${umapDomain}";

  services.restic.backups.daily.paths = [
    config.services.umap.stateDir
  ];
}
