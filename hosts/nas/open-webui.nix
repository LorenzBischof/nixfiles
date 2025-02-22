{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  services.open-webui = {
    enable = true;
    port = 6363;
    host = "0.0.0.0";
    environment = {
      WEBUI_AUTH_TRUSTED_EMAIL_HEADER = "Remote-Email";
      WEBUI_AUTH_TRUSTED_NAME_HEADER = "Remote-Name";
      DEFAULT_USER_ROLE = "admin";
      ENABLE_SIGNUP = "true";
      BYPASS_MODEL_ACCESS_CONTROL = "true";
    };
  };

  services.nginx.virtualHosts."chat.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.open-webui.port}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      enableAuthelia = true;
    };
  };

  homelab.dashboard.Services.Chat.href = "https://chat.${config.homelab.domain}";
}
