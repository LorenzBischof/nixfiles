# Debugging the home router (TP-Link Archer MR600, 192.168.0.1)

Not reachable from the sandboxed shell — run commands with the sandbox
disabled. Reachable from the framework laptop's own WiFi, and from `nas`
(see SSH section in `AGENTS.md`) for LAN-level checks (ARP, ping).

## API access

Use the `tplinkrouterc6u` Python library (packaged here, not in nixpkgs —
`packages/tplinkrouterc6u.nix`). Never hardcode the router password in
this repo; ask the user for it each session.

```bash
nix-shell -p "python3.withPackages (ps: [ (ps.callPackage ./packages/tplinkrouterc6u.nix {}) ])" --run "python3 - <<'EOF'
from tplinkrouterc6u import TplinkRouterProvider

router = TplinkRouterProvider.get_client('http://192.168.0.1', '<admin password>')
router.authorize()
print(router.get_status())   # wifi_2g_enable, wifi_5g_enable, connected devices, etc.
EOF"
```

For anything not covered by the library's dataclasses, use
`router.req_act([(act_type, oid, "0,0,0,0,0,0", "0,0,0,0,0,0", attrs)])`
directly. `SYSLOG_CFG` (`GET`, no attrs) gives logging config, not log
entries — never found the right OID for actual log content; ask the user
to export it from the web UI's System Log page instead (`log.txt`).

## Checking what's actually on the WiFi

The router's own status can lie (see bug below), so cross-check from `nas`
what's really associated at layer 2:

```bash
ping -c1 -W1 192.168.0.X                                                        # single host
for i in $(seq 1 254); do (ping -c1 -W1 192.168.0.$i >/dev/null 2>&1 &); done    # full sweep
ip neigh show | grep -i <mac-or-address>
```

A device never appearing in ARP (even transiently) means it's failing to
*associate*, not just failing DHCP/internet — a stronger signal than the
router's own "enable" flag.

## Known bug: AP isolation gets stuck enabled

Confirmed on this MR600, also reported on other Archer models: the router
can keep AP/client isolation active even when the web UI checkbox shows
disabled. Symptom: already-associated clients keep working, but no new
device can join that band — no failed auth logged, just silence for that
band. A reboot doesn't reliably clear it.

Fix: Wireless → Advanced, enable AP Isolation, save, then disable it
again, save. Expect it to recur.
