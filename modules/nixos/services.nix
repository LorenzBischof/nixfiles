{
  config,
  lib,
  pkgs,
  ...
}:
let
  # The entries declared through this module: the other my.services modules
  # (nixpkgs-age-monitor, …) declare entries of their own, without `ports`.
  cfg = lib.filterAttrs (_: s: s ? ports) config.my.services;

  # systemd's NFTSet= allows no `-` in a set name.
  clientsSet = name: "clients_${lib.replaceStrings [ "-" ] [ "_" ] name}";

  # Set on a new connection from user.slice in output, read in input once the
  # receiving socket is known. Outside tailscaled's 0xff0000 mask.
  fromUser = "0x20000000";

  # What the network may reach, a user may reach on this host too (sshd, nginx
  # on its own addresses, alloy). Port ranges stay closed.
  acceptOpen =
    proto:
    let
      fw = config.networking.firewall;
      ports = lib.unique (
        fw."allowed${proto}Ports"
        ++ lib.concatMap (i: i."allowed${proto}Ports") (lib.attrValues fw.interfaces)
      );
    in
    lib.optionalString (ports != [ ])
      "${lib.toLower proto} dport { ${lib.concatMapStringsSep ", " toString ports} } accept";

  # One rule per port: from a client's cgroup (level 2 is the unit,
  # system.slice/nginx.service, so its child cgroups match too) or a listed uid.
  serverRules =
    name:
    { ports, users, ... }:
    lib.concatMap (
      port:
      [ "tcp dport ${toString port} socket cgroupv2 level 2 @${clientsSet name} accept" ]
      # Numeric, so the build-time check needs no user database.
      ++
        lib.optional (users != [ ])
          "tcp dport ${toString port} meta skuid { ${
            lib.concatMapStringsSep ", " (u: toString config.users.users.${u}.uid) users
          } } accept"
    ) ports;

  allPorts = lib.concatMap (s: s.ports) (lib.attrValues cfg);

  # `requires` below declares the unit too, so look for an ExecStart, which
  # only a real service has (`script` sets one too).
  declared =
    name:
    config.systemd.services ? ${name} && config.systemd.services.${name}.serviceConfig ? ExecStart;

  assertions =
    name:
    { users, clients, ... }:
    [
      {
        assertion = declared name;
        message = "my.services.${name}: no such system service.";
      }
      {
        # NFTSet= adds the unit's own cgroup, and the rules match the unit at
        # level 2: a template instance or a unit with Slice= sits deeper, so
        # it would escape every rule for declared services.
        assertion = !(lib.hasInfix "@" name || config.systemd.services.${name}.serviceConfig ? Slice);
        message = "my.services.${name}: a template instance or a unit with Slice= can't be held to its rules.";
      }
    ]
    ++ map (user: {
      assertion = config.users.users ? ${user} && config.users.users.${user}.uid != null;
      message = "my.services.${name}.users: ${user} is not a user with a fixed uid.";
    }) users
    # Setting NFTSet= on a misspelled name would quietly create a unit.
    ++ map (client: {
      assertion = declared client;
      message = "my.services.${name}.clients: ${client} is not a system service.";
    }) clients;

  daemonReload = "${config.systemd.package}/bin/systemctl daemon-reload";

  # TODO: the iptables rules this replaced (d4225b2's per-port REJECTs, then
  # bb0b2da's loopback-clients chain) survive in iptables-nft's `ip filter`
  # table and would refuse clients that lost the groups they name. Delete
  # them once the new table is in place. Our own leftover, no upstream issue.
  # Drop once the vps has switched past this commit.
  dropIptablesLeftovers = pkgs.writeShellScript "drop-iptables-loopback-leftovers" ''
    iptables=${pkgs.iptables}/bin/iptables
    $iptables -w -S OUTPUT 2>/dev/null \
      | grep -e '-j loopback-clients' -e '^-A OUTPUT -o lo .*--gid-owner .*--suppl-groups -j REJECT' \
      | sed 's/^-A /-D /' \
      | while read -r rule; do
          $iptables -w $rule || echo "could not delete stale rule: $rule" >&2
        done
    for chain in loopback-clients loopback-refuse; do
      $iptables -w -F $chain 2>/dev/null && $iptables -w -X $chain
    done
    true
  '';

  entry = lib.types.submodule {
    options = {
      ports = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = ''
          The TCP ports the service listens on. Over loopback only its
          clients and users may connect to them.
        '';
      };
      clients = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          System services that may connect, matched by their cgroup. Only a
          unit directly in system.slice matches (no template instance, no
          Slice=), and a dropped client loses access only once restarted.
        '';
      };
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Users whose every process may connect, matched by uid.";
      };
      internet = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the service may reach anything beyond loopback, DNS
          included. Over loopback it reaches only the services that list it
          as a client either way.
        '';
      };
    };
  };
in
{
  options.my.services = lib.mkOption {
    type = lib.types.submodule { freeformType = lib.types.attrsOf entry; };
    default = { };
    description = ''
      Services by systemd unit name, closed by default: over loopback a
      declared service reaches only the services listing it as a client and is
      reached only by its clients and users, and without `internet` nothing
      else, DNS included. Independently, users and their Nix builds reach no
      system service over loopback beyond the ports the firewall opens; a
      socket-activated one (its socket is PID 1's) isn't covered. Refusals:
      `journalctl -k -g loopback-refused`.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = config.networking.nftables.enable;
        message = "my.services needs networking.nftables.enable.";
      }
      {
        # A flush on every reload would take other tables with it, such as the
        # rules tailscaled adds through iptables-nft.
        assertion = !config.networking.nftables.flushRuleset;
        message = "my.services needs networking.nftables.flushRuleset = false.";
      }
      {
        # They'd share who may connect. nginx.nix also checks them against
        # my.homelab.ports, but only with nginx enabled.
        assertion = lib.allUnique allPorts;
        message = "my.services: two services share a port.";
      }
    ]
    ++ lib.concatLists (lib.mapAttrsToList assertions cfg);

    # New connections only: once a client closes, the last packets can come
    # from a socket no process owns any more.
    networking.nftables.tables.loopback = {
      family = "inet";
      content = ''
        set services {
          type cgroupsv2
        }
        ${lib.concatMapStrings (name: ''
          set ${clientsSet name} {
            type cgroupsv2
          }
        '') (lib.attrNames cfg)}
        chain output {
          type filter hook output priority filter; policy accept;
          oif lo ct state new jump new_on_lo
        }

        chain new_on_lo {
          ${lib.concatStringsSep "\n  " (lib.concatLists (lib.mapAttrsToList serverRules cfg))}
          tcp dport { ${lib.concatMapStringsSep ", " toString allPorts} } jump refuse
          # A declared service reaches no other port on this host.
          socket cgroupv2 level 2 @services jump refuse
          # A user's process, or a build of theirs (a fixed-output build has the
          # host's network and runs in nix-daemon's cgroup): decided on arrival,
          # once the listener is known.
          meta skuid != 0 socket cgroupv2 level 1 "user.slice" ct mark set ct mark | ${fromUser}
          meta skgid ${toString config.ids.gids.nixbld} ct mark set ct mark | ${fromUser}
        }

        chain input {
          type filter hook input priority filter; policy accept;
          iif lo ct state new ct mark & ${fromUser} == ${fromUser} socket cgroupv2 level 1 "system.slice" jump user_to_system
        }

        chain user_to_system {
          ${acceptOpen "TCP"}
          ${acceptOpen "UDP"}
          jump refuse
        }

        chain refuse {
          limit rate 10/minute log prefix "loopback-refused: " flags skuid
          meta l4proto tcp reject with tcp reset
          reject
        }
      '';
    };

    # TODO: the build-time check loads the ruleset into an lkl kernel, which is
    # built without cgroups (nixpkgs' lkl-defconfig-enable-nftables has
    # NFT_SOCKET but not CGROUPS), so it refuses `socket cgroupv2` with
    # "Operation not supported". Check everything else. No upstream issue as of
    # 2026-11; drop once lklWithFirewall enables CONFIG_CGROUPS.
    networking.nftables.preCheckRuleset = ''
      sed -i '/socket cgroupv2/d' ruleset.conf
    '';

    systemd.services = lib.mkMerge (
      [
        {
          # Every load of the ruleset declares the sets anew, empty, and
          # systemd fills them only when a unit starts or on a daemon-reload
          # (NFTSet= in systemd.resource-control(5)). In between, under a
          # second, clients are refused and declared services aren't held to
          # their loopback targets. The table names user.slice, which must
          # exist when it loads.
          nftables = {
            wants = [ "user.slice" ];
            after = [ "user.slice" ];
            serviceConfig = {
              ExecStartPost = [
                "-${dropIptablesLeftovers}"
                daemonReload
              ];
              ExecReload = lib.mkAfter [ daemonReload ];
            };
          };
        }
        # Never running without the table. A switch only reloads nftables,
        # atomically, so a failed reload keeps the old table and stops nothing.
        (lib.mapAttrs (
          name:
          { internet, ... }:
          {
            requires = [ "nftables.service" ];
            after = [ "nftables.service" ];
            serviceConfig = {
              # A client of itself too: ovis's supervisor checks its server's
              # health over the port.
              NFTSet = [
                "cgroup:inet:loopback:services"
                "cgroup:inet:loopback:${clientsSet name}"
              ];
            }
            # In the kernel's cgroup BPF, so independent of the table. DNS goes
            # out through nscd, D-Bus (to resolved) and resolved's socket too.
            // lib.optionalAttrs (!internet) {
              IPAddressDeny = [ "any" ];
              IPAddressAllow = [
                "127.0.0.1"
                "::1"
              ];
              InaccessiblePaths = [
                "-/run/nscd"
                "-/run/dbus"
                "-/run/systemd/resolve"
              ];
            };
          }
        ) cfg)
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: c:
          # A switch that drops a client restarts it, since its NFTSet= changed,
          # and it comes back in no set. Adding or removing a service restarts
          # its clients for the same reason, nginx included.
          map (client: {
            ${client}.serviceConfig.NFTSet = [ "cgroup:inet:loopback:${clientsSet name}" ];
          }) c.clients
        ) cfg
      )
    );
  };
}
