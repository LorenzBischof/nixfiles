{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  services.syncthing = {
    enable = true;
    settings = {
      gui = {
        insecureSkipHostcheck = true;
      };
      options = {
        urAccepted = -1;
      };
      devices = {
        laptop.id = secrets.syncthing-devices.laptop;
        pixel-6a.id = secrets.syncthing-devices.pixel-6a;
        pixel-7.id = secrets.syncthing-devices.pixel-7;
        macbook.id = secrets.syncthing-devices.macbook;
        scanner.id = secrets.syncthing-devices.scanner;
      };
      folders = {
        home = {
          id = "jl3m1-4ls92";
          path = "~/home";
          devices = [
            "laptop"
            "pixel-6a"
            "pixel-7"
            "macbook"
          ];
        };
        files-lo = {
          id = "ztx9n-wzrke";
          path = "~/files-lo";
          devices = [
            "laptop"
            "pixel-6a"
          ];
        };
        paperless-consume = {
          id = "uukkv-dqhnx";
          path = config.services.paperless.consumptionDir;
          devices = [
            "pixel-6a"
            "pixel-7"
            "scanner"
          ];
        };
        photos = {
          id = "y9793-spumx";
          path = "~/photos";
          devices = [
            "pixel-6a"
            "pixel-7"
          ];
        };
      };
    };
  };
  systemd.tmpfiles.settings."10-paperless" = {
    ${config.services.paperless.consumptionDir}.d = {
      group = lib.mkForce config.services.syncthing.group;
      mode = "0770";
    };
  };
  services.nginx.virtualHosts."syncthing.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://${toString config.services.syncthing.guiAddress}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      enableAuthelia = true;
    };
  };

  systemd.services.syncthing.environment.STNODEFAULTFOLDER = "true"; # Don't create default ~/Sync folder

  services.restic.backups.daily.paths = [ config.services.syncthing.dataDir ];

  homelab.ports = [
    (builtins.elemAt (builtins.split ":" config.services.syncthing.guiAddress) 1)
  ];
  homelab.dashboard.Services.Syncthing.href = "https://syncthing.${config.homelab.domain}";
}
