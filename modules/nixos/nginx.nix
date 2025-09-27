{
  config,
  pkgs,
  lib,
  secrets,
  options,
  ...
}:
let
  cfg = config.my.homelab;
in
{
  options.my.homelab = {
    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.com";
      description = "The domain where services are reachable";
    };
    ports = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ ];
      description = "List of allocated port numbers";
    };
    nginx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable nginx with homelab configuration";
      };
      acme = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to enable ACME SSL certificates";
        };
        dnsProvider = lib.mkOption {
          type = lib.types.str;
          default = "cloudflare";
          description = "DNS provider for ACME challenges";
        };
        environmentFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Environment file for DNS provider credentials";
        };
        extraLegoFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "--dns.resolvers=1.1.1.1" ];
          description = "Extra flags to pass to lego";
        };
      };
    };
  };

  config = lib.mkIf cfg.nginx.enable (
    let
      duplicatePorts = lib.pipe options.my.homelab.ports.definitionsWithLocations [
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
        {
          assertion = cfg.nginx.acme.enable -> (cfg.nginx.acme.environmentFile != null);
          message = "my.homelab.nginx.acme.environmentFile must be set when ACME is enabled";
        }
      ];

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedTlsSettings = true;

        virtualHosts."_" = {
          default = true;
          rejectSSL = true;
          locations."/".return = 444;
        };
      };

      my.homelab.ports = [
        80
        443
      ];

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      security.acme = lib.mkIf cfg.nginx.acme.enable {
        acceptTerms = true;
        defaults.email = secrets.acme-email;
        certs."${cfg.domain}" = {
          dnsProvider = cfg.nginx.acme.dnsProvider;
          environmentFile = cfg.nginx.acme.environmentFile;
          extraDomainNames = [ "*.${cfg.domain}" ];
          group = "nginx";
          extraLegoFlags = cfg.nginx.acme.extraLegoFlags;
        };
      };
    }
  );
}
