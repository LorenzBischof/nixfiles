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
  services.open-webui = {
    enable = true;
    port = 6363;
    environment = {
      WEBUI_AUTH_TRUSTED_EMAIL_HEADER = "Remote-Email";
      WEBUI_AUTH_TRUSTED_NAME_HEADER = "Remote-Name";
      DEFAULT_USER_ROLE = "admin";
      ENABLE_SIGNUP = "true";
      BYPASS_MODEL_ACCESS_CONTROL = "true";
      HOME = config.services.open-webui.stateDir; # https://github.com/NixOS/nixpkgs/issues/411914
    };
  };

  services.nginx.virtualHosts."chat.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.open-webui.port}";
      proxyWebsockets = true;
      enableAuthelia = true;
    };
  };

  my.homelab.ports = [ config.services.open-webui.port ];
  my.homelab.dashboard.Services.Chat.href = "https://chat.${domain}";
}
