{
  config,
  pkgs,
  inputs,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  umapDomain = "umap.${domain}";

  # https://github.com/umap-project/umap/pull/3499
  oidcProviderLogo = pkgs.fetchurl {
    name = "oidc.png";
    url = "https://raw.githubusercontent.com/LorenzBischof/umap/af79689bed7e475573a81881eb631c92d9eab5ba/umap/static/umap/img/providers/oidc.png";
    hash = "sha256-T/Zhtp5AJouo9vGZHic06Vo00DixegB0EbQsxgy97L4=";
  };
  umapPackage = inputs.nixpkgs-umap.legacyPackages.x86_64-linux.umap.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      install -Dm444 ${oidcProviderLogo} umap/static/umap/img/providers/oidc.png
    '';
  });
in
{
  imports = [
    "${inputs.nixpkgs-umap}/nixos/modules/services/web-apps/umap.nix"
  ];

  # The module serves the Osmic icon set from `pkgs.osmic`, which only exists
  # on the umap branch, not in the nixpkgs this host is built from.
  nixpkgs.overlays = [
    (_self: _super: {
      inherit (inputs.nixpkgs-umap.legacyPackages.x86_64-linux) osmic;
    })
  ];

  # Disable NixOS manual generation to avoid umap module doc issues
  documentation.nixos.enable = false;

  services.umap = {
    enable = true;
    package = umapPackage;
    settings = {
      SITE_URL = "https://${umapDomain}";

      AUTHENTICATION_BACKENDS = [
        "social_core.backends.open_id_connect.OpenIdConnectAuth"
        "django.contrib.auth.backends.ModelBackend"
      ];
      SOCIAL_AUTH_OIDC_ENDPOINT = "https://auth.${domain}";
      SOCIAL_AUTH_OIDC_KEY = "umap";
      SOCIAL_AUTH_REDIRECT_IS_HTTPS = true;
    };
    # Provides SOCIAL_AUTH_OIDC_SECRET as an env var, kept out of the Nix store.
    environmentFile = config.age.secrets.umap-oidc-env.path;
    extraConfig = ''
      import os

      SOCIAL_AUTH_OIDC_SECRET = os.environ["SOCIAL_AUTH_OIDC_SECRET"]
    '';
  };

  services.authelia.instances.main.settings.identity_providers.oidc.clients = [
    {
      client_id = "umap";
      client_secret = secrets.authelia-clients-umap;
      authorization_policy = "one_factor";
      redirect_uris = [
        "https://${umapDomain}/complete/oidc/"
      ];
      scopes = [
        "openid"
        "email"
        "profile"
      ];
      consent_mode = "implicit";
    }
  ];

  services.nginx.virtualHosts."${umapDomain}" = {
    # The umap module sets enableACME = mkDefault true; override to use the shared wildcard cert instead.
    enableACME = false;
    useACMEHost = domain;
  };

  my.homelab.dashboard.Services.UMap.href = "https://${umapDomain}";

  services.restic.backups.daily.paths = [
    config.services.umap.stateDir
  ];
}
