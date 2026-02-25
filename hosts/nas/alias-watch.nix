{ config, ... }:
{
  services.alias-watch = {
    enable = true;
    environmentFile = config.age.secrets.alias-watch-env.path;
  };
}
