# my.system.egress.denyLAN (lan-egress.nix): non-root processes reach no
# private address off the host, except a listed resolver on port 53, resolved
# on port 53 and a my.services entry with egress.lan; root, the host's own
# addresses and replies to inbound connections pass.
{ pkgs }:
let
  web = port: "${pkgs.python3}/bin/python3 -m http.server --bind :: ${toString port}";
  ula = address: {
    networking.interfaces.eth1.ipv6.addresses = [
      {
        inherit address;
        prefixLength = 64;
      }
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "lan-egress";

  nodes.remote = {
    imports = [ (ula "fd00::2") ];
    # 53 stands in for a resolver: only the port matters.
    systemd.services = {
      web.wantedBy = [ "multi-user.target" ];
      web.serviceConfig.ExecStart = web 80;
      dns.wantedBy = [ "multi-user.target" ];
      dns.serviceConfig.ExecStart = web 53;
    };
    networking.firewall.allowedTCPPorts = [
      53
      80
    ];
  };

  nodes.machine = {
    imports = [
      ../modules/nixos/lan-egress.nix
      ../modules/nixos/services.nix
      (ula "fd00::1")
    ];
    my.system.egress = {
      denyLAN = true;
      dnsServers = [ "192.168.1.2" ];
    };
    services.resolved.enable = true;
    my.services = {
      lan.egress = {
        internet = true;
        lan = true;
      };
      online.egress.internet = true;
    };
    users.users.alice = {
      isNormalUser = true;
      uid = 1001;
    };
    systemd.services =
      let
        # Non-root, like the services my.services declares.
        sleeper = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            DynamicUser = true;
          };
        };
      in
      {
        # A non-root server, for replies to inbound connections.
        web = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = web 3000;
            DynamicUser = true;
          };
        };
        lan = sleeper;
        online = sleeper;
      };
    networking = {
      nftables.enable = true;
      firewall.allowedTCPPorts = [ 3000 ];
    };
  };

  testScript = ''
    curl = "${pkgs.curl}/bin/curl"

    def fetch(url):
        return f"{curl} -sS --max-time 5 -o /dev/null {url}"

    # A process of the unit itself, as its user: join its cgroup, then connect.
    def in_unit(unit, url):
        uid = machine.succeed(f"stat -c %u /proc/$(systemctl show -P MainPID {unit})").strip()
        return f"sh -c 'echo $$ > /sys/fs/cgroup$(systemctl show -P ControlGroup {unit}.service)/cgroup.procs && exec setpriv --reuid={uid} --regid={uid} --clear-groups -- {fetch(url)}'"

    def refused(name, cmd):
        with subtest(f"{name} is refused"):
            status, out = machine.execute(cmd)
            assert status == 7, f"{name}: expected connection refused (7), got {status}: {out}"

    start_all()
    remote.wait_for_open_port(53)
    remote.wait_for_open_port(80)
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(3000)

    for name, url in [("a private address", "http://192.168.1.2/"), ("a ULA", "http://[fd00::2]/")]:
        refused(f"alice on {name}", f"runuser -u alice -- {fetch(url)}")
        refused(f"a DynamicUser service on {name}", f"systemd-run -q --wait --pipe -p DynamicUser=yes -- {fetch(url)}")
        with subtest(f"root reaches {name}"):
            machine.succeed(fetch(url))
    machine.succeed("journalctl -k -g 'lan-egress-refused: .*DPT=80'")

    with subtest("a my.services entry with egress.lan reaches the LAN"):
        machine.wait_for_unit("lan.service")
        machine.wait_for_unit("online.service")
        for url in ("http://192.168.1.2/", "http://[fd00::2]/"):
            machine.succeed(in_unit("lan", url))
            refused(f"an online service without egress.lan on {url}", in_unit("online", url))

    with subtest("resolved reaches any resolver on port 53 only"):
        machine.succeed(f"setpriv --reuid=systemd-resolve --regid=systemd-resolve --clear-groups -- {fetch('http://[fd00::2]:53/')}")
        refused("resolved's user on port 80", f"setpriv --reuid=systemd-resolve --regid=systemd-resolve --clear-groups -- {fetch('http://[fd00::2]/')}")

    with subtest("a listed resolver is reachable on port 53 only"):
        machine.succeed(f"runuser -u alice -- {fetch('http://192.168.1.2:53/')}")
        refused("alice on the resolver's port 80", f"runuser -u alice -- {fetch('http://192.168.1.2/')}")

    with subtest("the host's own addresses are reachable"):
        for url in ("http://192.168.1.1:3000/", "http://[fd00::1]:3000/", "http://127.0.0.1:3000/"):
            machine.succeed(f"runuser -u alice -- {fetch(url)}")

    with subtest("inbound connections get their replies"):
        remote.succeed(fetch("http://192.168.1.1:3000/"))
        remote.succeed(fetch("http://[fd00::1]:3000/"))
  '';
}
