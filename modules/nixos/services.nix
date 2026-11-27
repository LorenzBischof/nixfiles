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

  # systemd's NFTSet= allows no `-` or `.` in a set name.
  clientsSet = name: "clients_${lib.replaceStrings [ "-" "." ] [ "_" "_" ] name}";

  # An entry names a service (`nginx`) or a slice (`system-immich.slice`).
  # The rules match a socket by its cgroup at level 2: a unit directly in
  # system.slice, or a slice directly in it, which holds every unit in it.
  isSlice = lib.hasSuffix ".slice";
  sliceBase = lib.removeSuffix ".slice";
  # The services a slice entry holds.
  members =
    slice:
    lib.attrNames (
      lib.filterAttrs (_: s: (s.serviceConfig.Slice or null) == slice) config.systemd.services
    );

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
  # system.slice/nginx.service, so its child cgroups match too, or a slice) or
  # a listed uid.
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

  # resolved's stub, where resolv.conf points: what doesn't ask nscd (a
  # fixed-output build, a Go binary built without cgo) resolves through it.
  # An offline service's IP filter doesn't keep it out, so the table does.
  toStub = "ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53";
  stubRule = rule: lib.optionalString config.services.resolved.enable "${toStub} ${rule}";

  # One set per localhost port, holding the declared services that may reach
  # it.
  localhostSet = port: "localhost_${toString port}";
  localhostPorts = lib.unique (lib.concatMap (s: s.egress.localhost) (lib.attrValues cfg));

  # `requires` below declares the unit too, so look for an ExecStart, which
  # only a real service has (`script` sets one too). A slice the module system
  # declares only through this module has no description.
  declared =
    name:
    if isSlice name then
      config.systemd.slices ? ${sliceBase name}
      && config.systemd.slices.${sliceBase name}.description != ""
    else
      config.systemd.services ? ${name} && config.systemd.services.${name}.serviceConfig ? ExecStart;

  # NFTSet= adds the unit's own cgroup, and the rules match at level 2: a
  # template instance, a unit with Slice= or a nested slice sits deeper, so
  # it would escape every rule.
  matchable =
    name:
    if isSlice name then
      builtins.match "system-[^-]+\\.slice" name != null
    else
      !(lib.hasInfix "@" name || config.systemd.services.${name}.serviceConfig ? Slice);
  unmatchable =
    name:
    if isSlice name then
      "a nested slice can't be held to its rules; declare the slice directly in system.slice"
    else
      "a template instance or a unit with Slice= can't be held to its rules; declare its slice${
        lib.optionalString (config.systemd.services.${name}.serviceConfig ? Slice)
          " (${config.systemd.services.${name}.serviceConfig.Slice})"
      } instead";

  assertions =
    name:
    {
      users,
      ingress,
      egress,
      ...
    }:
    [
      {
        assertion = declared name;
        message = "my.services.${name}: no such system service, or no slice declared with a description.";
      }
      {
        assertion = !declared name || matchable name;
        message = "my.services.${name}: ${unmatchable name}.";
      }
      {
        # The drop-ins hiding the DNS paths go to the units found here.
        assertion = isSlice name -> members name != [ ];
        message = "my.services.${name}: no system service has Slice=${name}.";
      }
      {
        # Without the internet, its IP filter refuses the LAN too.
        assertion = egress.lan -> egress.internet;
        message = "my.services.${name}.egress.lan needs egress.internet.";
      }
    ]
    ++ map (user: {
      assertion = config.users.users ? ${user} && config.users.users.${user}.uid != null;
      message = "my.services.${name}.users: ${user} is not a user with a fixed uid.";
    }) users
    # Setting NFTSet= on a misspelled name would quietly create a unit.
    ++ lib.concatMap (client: [
      {
        assertion = declared client;
        message = "my.services.${name}.ingress.from: ${client} is not a system service or slice.";
      }
      {
        assertion = !declared client || matchable client;
        message = "my.services.${name}.ingress.from: ${client}: ${unmatchable client}.";
      }
    ]) ingress.from;

  # Where an entry's own settings go: the service, or the slice. A slice's
  # resource control (NFTSet=, the IP filter) holds every unit in it.
  onUnit =
    name: attrs:
    if isSlice name then { slices.${sliceBase name} = attrs; } else { services.${name} = attrs; };
  configKey = name: if isSlice name then "sliceConfig" else "serviceConfig";

  daemonReload = "${config.systemd.package}/bin/systemctl daemon-reload";

  # The sets an entry's own cgroup goes in. A client of itself too: ovis's
  # supervisor checks its server's health over the port.
  ownSets =
    name: e:
    [
      "cgroup:inet:loopback:services"
      "cgroup:inet:loopback:${clientsSet name}"
    ]
    ++ lib.optional e.egress.internet "cgroup:inet:loopback:online"
    ++ lib.optional (e.egress.lan && config.my.system.egress.denyLAN) "cgroup:inet:lan_egress:lan"
    ++ map (port: "cgroup:inet:loopback:${localhostSet port}") e.egress.localhost;

  # Every set a slice's cgroup goes in, its own and as a client.
  sliceSets =
    slice:
    lib.optionals (cfg ? ${slice}) (ownSets slice cfg.${slice})
    ++ lib.mapAttrsToList (name: _: "cgroup:inet:loopback:${clientsSet name}") (
      lib.filterAttrs (_: e: lib.elem slice e.ingress.from) cfg
    );
  slices = lib.unique (
    lib.filter isSlice (lib.attrNames cfg ++ lib.concatMap (e: e.ingress.from) (lib.attrValues cfg))
  );

  offlinePaths = [
    "-/run/nscd"
    "-/run/dbus"
    "-/run/systemd/resolve"
    # tailscaled's LocalAPI, open to all, dials the tailnet and
    # 100.100.100.100 for any caller (see lan-egress.nix).
    "-/run/tailscale"
  ];

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
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Users whose every process may connect, matched by uid.";
      };
      ingress.from = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "nginx" ];
        description = ''
          System services or slices that may connect, matched by their
          cgroup. Only a unit directly in system.slice (no template instance,
          no Slice=) or a slice directly in it matches. A dropped service
          loses access once restarted, a dropped slice once the table
          reloads, which the switch does.
        '';
      };
      egress = {
        internet = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether the service may reach anything beyond loopback, DNS
            included. Without it the service isn't reachable from beyond
            loopback either: its IP filter holds both directions.
          '';
        };
        lan = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether the service may reach the private ranges that
            `my.system.egress.denyLAN` refuses (the LAN, the tailnet,
            link-local and ULA). Needs `internet`.
          '';
        };
        localhost = lib.mkOption {
          type = lib.types.listOf lib.types.port;
          default = [ ];
          example = [ 443 ];
          description = ''
            TCP ports on 127.0.0.1 of undeclared listeners that the service
            may reach, such as an nginx vhost listening there alone. A
            declared service's port stays limited to its `ingress.from`.
          '';
        };
      };
    };
  };
in
{
  # For egress.lan.
  imports = [ ./lan-egress.nix ];

  options.my.services = lib.mkOption {
    type = lib.types.submodule { freeformType = lib.types.attrsOf entry; };
    default = { };
    description = ''
      Services by systemd unit name, or slices by their name with `.slice`
      (one entry for every unit in it), closed by default: over loopback a
      declared service reaches only the services whose `ingress.from` lists
      it and is reached only by its own `ingress.from` and users, and
      without `egress.internet` nothing else, DNS included. Independently,
      users and their Nix builds reach no
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
      {
        # The rules refuse a declared port to all but its clients first.
        assertion = !lib.any (port: lib.elem port allPorts) localhostPorts;
        message = "my.services: an egress.localhost entry names a declared service's port; list the service in its ingress.from instead.";
      }
    ]
    ++ lib.concatLists (lib.mapAttrsToList assertions cfg);

    # New connections only: once a client closes, the last packets can come
    # from a socket no process owns any more.
    networking.nftables.tables.loopback = {
      family = "inet";
      content = ''
        # A slice isn't restarted when the sets it goes in change, and its
        # cgroup stays in the old ones. Listed here, a change reloads the
        # table, which empties them, and nftables' daemon-reload refills them.
        ${lib.concatMapStrings (slice: "# ${slice}: ${toString (sliceSets slice)}\n") slices}
        set services {
          type cgroupsv2
        }
        set online {
          type cgroupsv2
        }
        ${lib.concatMapStrings (set: ''
          set ${set} {
            type cgroupsv2
          }
        '') (map clientsSet (lib.attrNames cfg) ++ map localhostSet localhostPorts)}
        chain output {
          type filter hook output priority filter; policy accept;
          oif lo ct state new jump new_on_lo
        }

        chain new_on_lo {
          ${stubRule "socket cgroupv2 level 2 @online accept"}
          ${lib.concatStringsSep "\n  " (lib.concatLists (lib.mapAttrsToList serverRules cfg))}
          ${lib.optionalString (allPorts != [ ])
            "tcp dport { ${lib.concatMapStringsSep ", " toString allPorts} } jump refuse"
          }
          ${lib.concatMapStringsSep "\n  " (
            port:
            "ip daddr 127.0.0.1 tcp dport ${toString port} socket cgroupv2 level 2 @${localhostSet port} accept"
          ) localhostPorts}
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
          ${stubRule "accept"}
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

    systemd = lib.mkMerge (
      [
        {
          # Every load of the ruleset declares the sets anew, empty, and
          # systemd fills them only when a unit starts or on a daemon-reload
          # (NFTSet= in systemd.resource-control(5)). In between, under a
          # second, clients are refused and declared services aren't held to
          # their loopback targets. The table names user.slice, which must
          # exist when it loads.
          services.nftables = {
            wants = [ "user.slice" ];
            after = [ "user.slice" ];
            serviceConfig = {
              ExecStartPost = [ daemonReload ];
              ExecReload = lib.mkAfter [ daemonReload ];
            };
          };

          # The DNS paths aren't resource control, so a slice can't hide them
          # from what it holds: each unit in it gets a drop-in. Through
          # systemd.packages, since naming the units in systemd.services by
          # their Slice= would be defined by itself.
          packages = lib.concatLists (
            lib.mapAttrsToList (
              name: e:
              lib.optionals (isSlice name && !e.egress.internet) (
                map (
                  unit:
                  pkgs.writeTextDir "lib/systemd/system/${unit}.service.d/my-services-offline.conf" ''
                    [Service]
                    InaccessiblePaths=${toString offlinePaths}
                    # A unit's own IPAddressAllow= would win over the slice's
                    # deny, so empty it and repeat the slice's filter.
                    IPAddressAllow=
                    IPAddressAllow=127.0.0.1 ::1
                    IPAddressDeny=any
                  ''
                ) (members name)
              )
            ) cfg
          );
        }
      ]
      ++ lib.mapAttrsToList (
        name: e:
        onUnit name {
          # Never running without the table: a slice's units stop with it. A
          # switch only reloads nftables, atomically, so a failed reload keeps
          # the old table and stops nothing.
          requires = [ "nftables.service" ];
          after = [ "nftables.service" ];
          ${configKey name} = {
            NFTSet = ownSets name e;
          }
          # In the kernel's cgroup BPF, so independent of the table.
          // lib.optionalAttrs (!e.egress.internet) {
            IPAddressDeny = [ "any" ];
            IPAddressAllow = [
              "127.0.0.1"
              "::1"
            ];
          }
          # DNS goes out through nscd, D-Bus (to resolved) and resolved's
          # socket too, and anywhere through tailscaled's LocalAPI.
          // lib.optionalAttrs (!e.egress.internet && !isSlice name) {
            InaccessiblePaths = offlinePaths;
          };
        }
      ) cfg
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: e:
          # A switch that drops a client restarts it, since its NFTSet= changed,
          # and it comes back in no set. Adding or removing a service restarts
          # its clients for the same reason, nginx included.
          map (
            client:
            onUnit client { ${configKey client}.NFTSet = [ "cgroup:inet:loopback:${clientsSet name}" ]; }
          ) e.ingress.from
        ) cfg
      )
    );
  };
}
