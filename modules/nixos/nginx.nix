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
    homelab.nginx = {
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

  config = lib.mkIf config.homelab.nginx.enable (
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
        {
          assertion = config.homelab.nginx.acme.enable -> (config.homelab.nginx.acme.environmentFile != null);
          message = "homelab.nginx.acme.environmentFile must be set when ACME is enabled";
        }
      ];

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedTlsSettings = true;

        virtualHosts."_" = {
          useACMEHost = lib.mkIf config.homelab.nginx.acme.enable config.homelab.domain;
          addSSL = config.homelab.nginx.acme.enable;
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

      security.acme = lib.mkIf config.homelab.nginx.acme.enable {
        acceptTerms = true;
        defaults.email = secrets.acme-email;
        certs."${config.homelab.domain}" = {
          dnsProvider = config.homelab.nginx.acme.dnsProvider;
          environmentFile = config.homelab.nginx.acme.environmentFile;
          extraDomainNames = [ "*.${config.homelab.domain}" ];
          group = "nginx";
          extraLegoFlags = config.homelab.nginx.acme.extraLegoFlags;
        };
      };
    }
  );
}
