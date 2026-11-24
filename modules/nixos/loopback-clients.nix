{ config, lib, ... }:
let
  cfg = config.my.homelab.loopbackClients;

  allow = port: match: "-A loopback-clients -p tcp --dport ${port} -m owner ${match} -j RETURN";
  rules =
    port:
    { users, groups }:
    map (user: allow port "--uid-owner ${user}") users
    ++ map (group: allow port "--gid-owner ${group} --suppl-groups") groups
    ++ [ "-A loopback-clients -p tcp --dport ${port} -j loopback-refuse" ];

  # Connection attempts only: once a client closes, the last packets come from
  # a socket no process owns, which no owner match accepts.
  jump = "-o lo -p tcp --syn -j loopback-clients";

  declared =
    kind: port: names:
    map (name: {
      assertion = config.users.${kind} ? ${name};
      message = "my.homelab.loopbackClients.${port}: ${name} is not declared in users.${kind}.";
    }) names;
in
{
  options.my.homelab.loopbackClients = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          users = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Static users that may connect, matched by uid.";
          };
          groups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Groups whose members may connect.";
          };
        };
      }
    );
    default = { };
    description = ''
      IPv4 loopback TCP ports, each with who may connect to it: every local
      process can reach loopback, so a service with no auth of its own is
      closed to everyone else. Refusals are logged with the uid
      (`journalctl -k -g loopback-refused`).

      Name a static user in `users`, not a group it joins: its running
      processes would keep their old groups until restarted by hand. A
      DynamicUser service has no fixed uid: give it a group through
      SupplementaryGroups, which switch restarts it for, and name that group.
    '';
  };

  # iptables cannot resolve an undeclared name, and that aborts the whole
  # firewall start.
  config.assertions = lib.concatLists (
    lib.mapAttrsToList (port: c: declared "users" port c.users ++ declared "groups" port c.groups) cfg
  );

  # Declaring a chain in iptables-restore --noflush empties it, so every
  # firewall start or reload replaces the whole set in one step: a change takes
  # effect on switch and no port is open in between. Never unhooked on stop: a
  # reload runs the stop commands first, and these rules only ever refuse.
  #
  # The script runs under `sh -e`, and a failure would abort it before the
  # inbound firewall is hooked in. A failed restore changes nothing, so carry on
  # with the previous rules instead.
  config.networking.firewall.extraCommands = ''
    iptables-restore -w --noflush <<'EOF' || echo "loopback-clients: iptables-restore failed, keeping the previous rules" >&2
    *filter
    :loopback-clients - [0:0]
    :loopback-refuse - [0:0]
    -A loopback-refuse -m limit --limit 10/min -j LOG --log-prefix "loopback-refused: " --log-uid
    -A loopback-refuse -j REJECT
    ${lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList rules cfg))}
    COMMIT
    EOF
    iptables -w -C OUTPUT ${jump} 2>/dev/null || iptables -w -I OUTPUT ${jump}
  '';
}
