{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
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

  services.nginx.virtualHosts."jellyfin.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8096";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  services.nginx.virtualHosts."radarr.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.radarr.settings.server.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  services.nginx.virtualHosts."sonarr.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.sonarr.settings.server.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  services.nginx.virtualHosts."readarr.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.readarr.settings.server.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  services.nginx.virtualHosts."nzbget.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:6789";
      enableAuthelia = true;
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  services.nginx.virtualHosts."audiobookshelf.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.audiobookshelf.port}";
      enableAuthelia = true;
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  homelab.ports = [
    config.services.audiobookshelf.port
    config.services.radarr.settings.server.port
    config.services.sonarr.settings.server.port
    config.services.readarr.settings.server.port
    6789
    8096
  ];

  homelab.dashboard.Media = {
    Jellyfin.href = "https://jellyfin.${config.homelab.domain}";
    Radarr.href = "https://radarr.${config.homelab.domain}";
    Sonarr.href = "https://sonarr.${config.homelab.domain}";
    Readarr.href = "https://readarr.${config.homelab.domain}";
    NZBGet.href = "https://nzbget.${config.homelab.domain}";
    Audiobookshelf.href = "https://audiobookshelf.${config.homelab.domain}";
  };
}
