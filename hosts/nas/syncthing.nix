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
  services.syncthing = {
    enable = true;
    openDefaultPorts = true;
    settings = {
      gui = {
        insecureSkipHostcheck = true;
      };
      options = {
        urAccepted = -1;
      };
      devices = {
        framework.id = secrets.syncthing-devices.framework;
        pixel-7.id = secrets.syncthing-devices.pixel-7;
        macbook.id = secrets.syncthing-devices.macbook;
        scanner.id = secrets.syncthing-devices.scanner;
        pixel-9a-l.id = secrets.syncthing-devices.pixel-9a-l;
        pixel-9a-t.id = secrets.syncthing-devices.pixel-9a-t;
      };
      folders = {
        home = {
          id = "jl3m1-4ls92";
          path = "~/home";
          devices = [
            "pixel-7"
            "macbook"
            "framework"
            "pixel-9a-l"
            "pixel-9a-t"
          ];
        };
        files-lo = {
          id = "ztx9n-wzrke";
          path = "~/files-lo";
          devices = [
            "framework"
            "pixel-9a-l"
          ];
        };
        paperless-consume = {
          id = "uukkv-dqhnx";
          path = config.services.paperless.consumptionDir;
          devices = [
            "pixel-7"
            "scanner"
            "pixel-9a-l"
            "pixel-9a-t"
          ];
        };
        photos = {
          id = "y9793-spumx";
          path = "~/photos";
          devices = [
            "pixel-7"
            "pixel-9a-l"
            "pixel-9a-t"
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
  services.nginx.virtualHosts."syncthing.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://${toString config.services.syncthing.guiAddress}";
      proxyWebsockets = true;
      enableAuthelia = true;
    };
  };

  systemd.services.syncthing.environment.STNODEFAULTFOLDER = "true"; # Don't create default ~/Sync folder

  services.restic.backups.daily.paths = [ config.services.syncthing.dataDir ];

  my.homelab.ports = [
    (builtins.elemAt (builtins.split ":" config.services.syncthing.guiAddress) 1)
  ];
  my.homelab.dashboard.Services.Syncthing.href = "https://syncthing.${domain}";
}
