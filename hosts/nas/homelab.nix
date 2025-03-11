{
  config,
  pkgs,
  lib,
  secrets,
  options,
  ...
}:
{
  options = {
    homelab.domain = lib.mkOption {
      type = lib.types.str;
      example = "example.com";
      description = "The domain where services are reachable";
    };
    homelab.ports = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ ];
      description = "List of allocated port numbers";
    };
  };
  config =
    let
      duplicatePorts = lib.pipe options.homelab.ports.definitionsWithLocations [
        # Expand entries with multiple ports into individual port entries
        (lib.concatMap (
          entry:
          map (port: {
            file = entry.file;
            port = port;
          }) entry.value
        ))
        (lib.groupBy (entry: toString entry.port))
        (lib.filterAttrs (port: entries: builtins.length entries > 1))
        (lib.mapAttrsToList (
          port: entries:
          "Duplicate port ${port} found in:\n" + lib.concatMapStrings (entry: "  - ${entry.file}\n") entries
        ))
        (lib.concatStrings)
      ];
    in
    {
      assertions = [
        {
          assertion = duplicatePorts == "";
          message = duplicatePorts;
        }
      ];

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedTlsSettings = true;

        virtualHosts."_" = {
          useACMEHost = config.homelab.domain;
          addSSL = true;
          default = true;
          locations."/".return = 404;
        };
      };

      homelab.ports = [
        80
        443
      ];
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      security.acme = {
        acceptTerms = true;
        defaults.email = secrets.acme-email;
        certs."${config.homelab.domain}" = {
          dnsProvider = "cloudflare";
          environmentFile = config.age.secrets.cloudflare-token.path;
          extraDomainNames = [ "*.${config.homelab.domain}" ];
          group = "nginx";
          # For some reason the TXT challenge could not be resolved otherwise
          extraLegoFlags = [ "--dns.resolvers=1.1.1.1" ];
        };
      };
    };
}
