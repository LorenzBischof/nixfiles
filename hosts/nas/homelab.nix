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
      # Flatten the list to have one entry per port
      flattenedEntries = lib.flatten (
        map (
          entry:
          map (port: {
            file = entry.file;
            port = toString port;
          }) entry.value
        ) options.homelab.ports.definitionsWithLocations # We could probably just get all the virtualhost proxyPass options
      );

      # Group entries by their value
      groupedByValue = lib.groupBy (entry: toString entry.port) flattenedEntries;

      # Find values that appear more than once
      duplicateEntries = lib.filterAttrs (value: entries: builtins.length entries > 1) groupedByValue;

      # Format error messages for duplicates
      formatDuplicateError =
        value: entries:
        "Duplicate value ${value} found in:\n"
        + lib.concatMapStrings (entry: "  - ${entry.file}\n") entries;

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
