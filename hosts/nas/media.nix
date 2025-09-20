{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
in
{
  users.groups.media = { };

  systemd.tmpfiles.settings."10-media" = {
    "/data/audiobooks".d = {
      group = "media";
      mode = "0770";
    };
    "/data/movies".d = {
      group = "media";
      mode = "0770";
    };
    "/data/tv".d = {
      group = "media";
      mode = "0770";
    };
  };

  services = {
    jellyfin = {
      enable = true;
      group = "media";
    };
    radarr = {
      enable = true;
      group = "media";
    };
    sonarr = {
      enable = true;
      group = "media";
    };
    readarr = {
      enable = true;
      group = "media";
    };
    nzbget = {
      enable = true;
      group = "media";
      settings = {
        ControlPassword = "";
      };
    };
    audiobookshelf = {
      enable = true;
      group = "media";
    };
  };

  services.nginx.virtualHosts."jellyfin.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8096";
      proxyWebsockets = true;
    };
  };

  services.nginx.virtualHosts."radarr.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.radarr.settings.server.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
    };
  };

  services.nginx.virtualHosts."sonarr.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.sonarr.settings.server.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
    };
  };

  services.nginx.virtualHosts."readarr.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.readarr.settings.server.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
    };
  };

  services.nginx.virtualHosts."nzbget.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:6789";
      enableAuthelia = true;
      proxyWebsockets = true;
    };
  };

  services.nginx.virtualHosts."audiobookshelf.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.audiobookshelf.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
    };
  };

  my.homelab.ports = [
    config.services.audiobookshelf.port
    config.services.radarr.settings.server.port
    config.services.sonarr.settings.server.port
    config.services.readarr.settings.server.port
    6789
    8096
  ];

  my.homelab.dashboard.Media = {
    Jellyfin.href = "https://jellyfin.${domain}";
    Radarr.href = "https://radarr.${domain}";
    Sonarr.href = "https://sonarr.${domain}";
    Readarr.href = "https://readarr.${domain}";
    NZBGet.href = "https://nzbget.${domain}";
    Audiobookshelf.href = "https://audiobookshelf.${domain}";
  };
}
