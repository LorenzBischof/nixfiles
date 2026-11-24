{ config, lib, ... }:
let
  rule =
    port: group:
    "OUTPUT -o lo -p tcp --dport ${port} -m owner ! --gid-owner ${group} --suppl-groups -j REJECT";
in
{
  options.my.homelab.loopbackClients = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = ''
      IPv4 loopback TCP ports, each with the one group whose members may
      connect to it: every local process can reach loopback, so a service with
      no auth of its own is closed to everyone else. A DynamicUser service
      joins the group through SupplementaryGroups.

      Rules are only ever added, so changing or removing a port's group leaves
      its old rule in place until reboot. That fails closed: the port refuses
      everyone outside both groups, or stays closed after removal.
    '';
  };

  # A group iptables cannot find would abort the whole firewall start.
  config.assertions = lib.mapAttrsToList (port: group: {
    assertion = config.users.groups ? ${group};
    message = "my.homelab.loopbackClients.${port}: group ${group} is not declared in users.groups.";
  }) config.my.homelab.loopbackClients;

  # `-C` first so a firewall reload doesn't add duplicates. Never removed: a
  # reload runs extraStopCommands before extraCommands, which would leave the
  # port open for a moment, and a leftover rule only refuses.
  config.networking.firewall.extraCommands = lib.concatStrings (
    lib.mapAttrsToList (port: group: ''
      iptables -w -C ${rule port group} 2>/dev/null || iptables -w -I ${rule port group}
    '') config.my.homelab.loopbackClients
  );
}
