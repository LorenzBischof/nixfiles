{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  photosDir = "/data/photos";
in
{
  users.groups.photos = { };
  users.users.immich.extraGroups = [ "syncthing" ];
  users.users.syncthing.homeMode = "0750";

  systemd.tmpfiles.settings."10-photos" = {
    ${photosDir}.d = {
      user = "immich";
      group = "photos";
      mode = "0550";
    };
  };
  services.restic.backups.daily.paths = [ photosDir ];

  services.immich = {
    enable = true;
    #group = "photos";  # https://github.com/NixOS/nixpkgs/issues/344738
    machine-learning.enable = false;
  };

  services.nginx.virtualHosts."immich.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.immich.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
      extraConfig = ''
        # allow large file uploads
        client_max_body_size 1000M;

        # set timeout
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        send_timeout       600s;
      '';
    };
  };

  homelab.ports = [ config.services.immich.port ];
  homelab.dashboard.Services.Immich.href = "https://immich.${config.homelab.domain}";
}
