# my.services (services.nix): who is let in over loopback, what a declared
# service may reach, that users reach no other system service, that the sets
# stay filled across what empties or changes them, and that no declared service
# runs without the table.
{ pkgs }:
let
  server = port: "${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 ${toString port}";

  common = {
    imports = [ ../modules/nixos/services.nix ];
    networking.nftables.enable = true;
    # Its stub on 127.0.0.53, as on the nas.
    services.resolved.enable = true;

    users.users = {
      alice = {
        isNormalUser = true;
        uid = 1001;
      };
      bob = {
        isNormalUser = true;
        uid = 1002;
      };
    };

    systemd.services =
      let
        sleeper = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      in
      {
        test-server = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = server 3001;
        };
        client = sleeper;
        other = sleeper;
        # Declared, offline, a client of `online` only.
        offline = sleeper;
        online = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = server 3007;
        };
        # Undeclared system services: one closed to users, one the firewall
        # opens.
        plain = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = server 3005;
        };
        public = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 0.0.0.0 3006";
        };
      };
    networking.firewall.allowedTCPPorts = [ 3006 ];

    my.services = {
      test-server = {
        ports = [ 3001 ];
        clients = [ "client" ];
        users = [ "alice" ];
      };
      online = {
        ports = [ 3007 ];
        clients = [ "offline" ];
        internet = true;
      };
      offline = { };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "services";

  nodes.remote = {
    systemd.services.web = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 0.0.0.0 80";
    };
    networking.firewall.allowedTCPPorts = [ 80 ];
  };

  nodes.machine =
    { lib, ... }:
    {
      imports = [ common ];

      specialisation.moved.configuration = {
        systemd.services.test-server.serviceConfig.ExecStart = lib.mkForce (server 3003);
        my.services.test-server.ports = lib.mkForce [ 3003 ];
      };

      # The client taken off, the port kept.
      specialisation.revoked.configuration = {
        my.services.test-server.clients = lib.mkForce [ ];
      };
    };

  testScript = ''
    curl = "${pkgs.curl}/bin/curl"
    # Straight to resolved's stub, past nscd. resolved answers from /etc/hosts.
    resolves = "${pkgs.dig}/bin/dig +time=2 +tries=1 +short @127.0.0.53 remote | ${pkgs.gnugrep}/bin/grep -qxE '[0-9.]+'"

    def fetch(port, host="127.0.0.1"):
        return f"{curl} -sS --max-time 5 -o /dev/null http://{host}:{port}/"

    # A process of the unit itself: join its cgroup, then connect. Its IP
    # filter comes with the cgroup, its mount namespace doesn't.
    def in_unit(unit, port, host="127.0.0.1"):
        return f"sh -c 'echo $$ > /sys/fs/cgroup/system.slice/{unit}.service/cgroup.procs && exec {fetch(port, host)}'"

    # A process of a user's own, in user.slice like a login or an agent.
    def as_user(user, port, host="127.0.0.1"):
        return f"systemd-run -q --wait --pipe --uid={user} --slice=user.slice -- {fetch(port, host)}"

    def refused(name, cmd):
        with subtest(f"{name} is refused"):
            status, out = machine.execute(cmd)
            assert status == 7, f"{name}: expected connection refused (7), got {status}: {out}"

    def check(port, client=True):
        clients = [("client unit", in_unit("client", port))]
        for name, cmd in (clients if client else []) + [
            ("alice", f"runuser -u alice -- {fetch(port)}"),
            ("alice in user.slice", as_user("alice", port)),
        ]:
            with subtest(f"{name} reaches {port}"):
                machine.succeed(cmd)
        for name, cmd in ([] if client else clients) + [
            ("unlisted unit", in_unit("other", port)),
            ("bob", f"runuser -u bob -- {fetch(port)}"),
            ("bob in user.slice", as_user("bob", port)),
            ("root in the test backdoor", fetch(port)),
            ("a declared service that isn't a client", in_unit("offline", port)),
        ]:
            refused(f"{name} on {port}", cmd)

    def listening(port):
        machine.wait_until_succeeds(f"ss -Hltn 'sport = :{port}' | grep -q .")

    def switch(to):
        # The timeout turns a hung switch into a clear failure.
        return machine.succeed(f"timeout 300 /run/booted-system/{to}/bin/switch-to-configuration test 2>&1")

    remote.wait_for_open_port(80)
    machine.wait_for_unit("multi-user.target")
    listening(3001)
    check(3001)
    machine.succeed("journalctl -k -g 'loopback-refused: .*DPT=3001'")

    with subtest("users and system services"):
        for port in (3005, 3006):
            listening(port)
        refused("bob in user.slice on an undeclared system service", as_user("bob", 3005))
        refused("bob in user.slice on it through the machine's own address", as_user("bob", 3005, "machine"))
        machine.succeed(as_user("bob", 3006))
        machine.succeed(in_unit("other", 3005))
        # A build runs in nix-daemon's cgroup, with the nixbld group.
        refused("a nix build user on an undeclared system service", f"setpriv --reuid=30001 --regid=30000 --clear-groups -- {fetch(3005)}")

    with subtest("resolved's stub answers users, builds and online services"):
        machine.wait_for_unit("systemd-resolved.service")
        machine.succeed(f"systemd-run -q --wait --pipe --uid=bob --slice=user.slice -- ${pkgs.bash}/bin/sh -c '{resolves}'")
        machine.succeed(f"setpriv --reuid=30001 --regid=30000 --clear-groups -- sh -c '{resolves}'")
        machine.succeed(f"sh -c 'echo $$ > /sys/fs/cgroup/system.slice/online.service/cgroup.procs && {resolves}'")
        status, out = machine.execute("sh -c 'echo $$ > /sys/fs/cgroup/system.slice/offline.service/cgroup.procs && ${pkgs.dig}/bin/dig +time=2 +tries=1 @127.0.0.53 remote'")
        assert status != 0 and ("refused" in out or "timed out" in out), f"offline service reached the stub: {status}: {out}"

    with subtest("a declared service reaches its targets and nothing else"):
        listening(3007)
        machine.succeed(in_unit("offline", 3007))
        machine.succeed(in_unit("online", 3007))
        refused("offline on an undeclared system service", in_unit("offline", 3005))
        refused("online on an undeclared system service", in_unit("online", 3005))
        machine.succeed(in_unit("online", 80, "remote"))
        machine.fail(in_unit("offline", 80, "remote"))
        machine.succeed(in_unit("other", 80, "remote"))
        pid = machine.succeed("systemctl show -P MainPID offline").strip()
        for path in ("/run/nscd", "/run/dbus"):
            machine.succeed(f"ls -A {path} | grep -q .")
            machine.succeed(f"nsenter -t {pid} -m -- sh -c '! ls -A {path} 2>/dev/null | grep -q .'")

    with subtest("a restarted client unit is let in again"):
        machine.succeed("systemctl restart client")
        check(3001)

    with subtest("reloading nftables refills the sets"):
        machine.succeed("systemctl reload nftables")
        check(3001)

    with subtest("restarting nftables refills the sets"):
        machine.succeed("systemctl restart nftables")
        listening(3001)
        check(3001)

    with subtest("stopping nftables takes the server down"):
        machine.succeed("systemctl stop nftables")
        machine.fail("systemctl is-active test-server")
        refused("unlisted unit with nftables stopped", in_unit("other", 3001))
        machine.succeed("systemctl start test-server offline online")
        machine.succeed("systemctl is-active nftables")
        listening(3001)
        check(3001)

    with subtest("a reload that fails keeps the previous table"):
        rules = machine.succeed("grep -o '/nix/store/[^ ]*-nftables-rules' /etc/systemd/system/nftables.service | head -1").strip()
        machine.succeed(f"sed 's/reject with tcp reset/jump nowhere/' {rules} > /tmp/broken-rules && chmod +x /tmp/broken-rules && mount --bind /tmp/broken-rules {rules}")
        machine.fail("systemctl reload nftables")
        machine.succeed(f"umount {rules}")
        machine.succeed("systemctl is-active nftables test-server")
        check(3001)

    with subtest("units started before the table at boot are let in"):
        # Not reboot(): virtiofsd exits with the guest, and only start()
        # brings it back for the store.
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        listening(3001)
        check(3001)

    with subtest("a switch that moves the port"):
        switch("specialisation/moved")
        listening(3003)
        check(3003)

    with subtest("a switch that takes the client off, leaving the table as it was"):
        switch("")
        listening(3001)
        out = switch("specialisation/revoked")
        # Revoked by the client's restart alone, with no reload to empty the set.
        assert "starting the following units: client.service\n" in out, out
        assert "nftables.service" not in out, out
        check(3001, client=False)
  '';
}
