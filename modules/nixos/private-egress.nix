{ config, lib, ... }:
let
  cfg = config.my.system.privateEgress;

  isV6 = lib.hasInfix ":";
  dns =
    family: addrs:
    lib.optionalString (addrs != [ ])
      "${family} daddr { ${lib.concatStringsSep ", " addrs} } meta l4proto { tcp, udp } th dport 53 accept";
in
{
  options.my.system.privateEgress = {
    enable = lib.mkEnableOption ''
      refusing new connections from non-root processes to private, CGNAT
      (tailnet) and link-local addresses off the host. Refusals:
      `journalctl -k -g private-egress-refused`
    '';
    dnsServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Lookups run as the caller or nscd's user, not root.
      default = lib.optionals config.services.tailscale.enable [
        "100.100.100.100"
        "fd7a:115c:a1e0::53"
      ];
      description = "Resolvers inside the blocked ranges that stay reachable, on port 53 only.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.nftables.enable;
        message = "my.system.privateEgress needs networking.nftables.enable.";
      }
    ];

    # New connections only: replies to inbound ones and the kernel's own
    # packets (resets, ICMP errors) aren't `ct state new`.
    #
    # TODO: root is exempt, and tailscaled is root: its LocalAPI socket is
    # 0666 on Linux by design, and its `dial` endpoint (`tailscale nc`)
    # checks no permission, so any local user can have tailscaled connect
    # to these ranges (and to any loopback port) for them. No upstream issue
    # as of 2026-11 (tailscale 1.104.6). Drop once tailscaled gates `dial`
    # behind write permission, or close it here by making /run/tailscale
    # 0750 with a group only tailscale-nginx-auth joins (agents and ovis
    # then lose `tailscale status`).
    networking.nftables.tables.private_egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          oif lo accept
          ${dns "ip" (lib.filter (a: !isV6 a) cfg.dnsServers)}
          ${dns "ip6" (lib.filter isV6 cfg.dnsServers)}
          ct state new meta skuid != 0 ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } jump refuse
          ct state new meta skuid != 0 ip6 daddr { fc00::/7, fe80::/10 } jump refuse
        }

        chain refuse {
          limit rate 10/minute log prefix "private-egress-refused: " flags skuid
          meta l4proto tcp reject with tcp reset
          reject
        }
      '';
    };
  };
}
