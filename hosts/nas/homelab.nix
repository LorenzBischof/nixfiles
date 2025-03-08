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
      # The entries could contain multiple ports per file
      # We want every entry to have a single port
      flattened = lib.flatten (
        map (
          entry:
          map (port: {
            file = entry.file;
            port = port;
          }) entry.value
        ) options.homelab.ports.definitionsWithLocations # We could probably just get all the virtualhost proxyPass options
      );

      # Group entries by port
      groupedByPort = lib.groupBy (entry: toString entry.port) flattened;

      # Find ports that appear more than once
      duplicateEntries = lib.filterAttrs (port: entries: builtins.length entries > 1) groupedByPort;

      # Format error messages for duplicates
      formatDuplicateError =
        port: entries:
        "Duplicate port ${port} found in:\n" + lib.concatMapStrings (entry: "  - ${entry.file}\n") entries;

      duplicateErrors = lib.mapAttrsToList formatDuplicateError duplicateEntries;

      errorMsg = lib.concatStrings duplicateErrors;
    in
    {
      assertions = [
        {
          assertion = duplicateErrors == [ ];
          message = errorMsg;
        }
      ];

      services.nginx = {
        enable = true;

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
