---
name: lifx-onboarding
description: Use when a LIFX bulb won't (re)join the WiFi — the LIFX app says "couldn't connect to your wifi network" — or to find, identify or rename LIFX bulbs on the LAN. Onboards a reset bulb from framework over its setup AP, bypassing the app.
---

# LIFX onboarding

Run everything on framework with the sandbox disabled; the scripts need
`python3` (`nix-shell -p python3 --run …`) and NetworkManager.

## Which bulb is which

LIFX MACs start with `d0:73:d5`; the setup AP is named `LIFX <model> <last 6 of MAC>`.

```bash
python3 .agents/skills/lifx-onboarding/scripts/lifx.py find          # probes 192.168.0.1-254, prints ip + label
python3 .agents/skills/lifx-onboarding/scripts/lifx.py label <ip> [new-name]
```

A bulb that isn't in `find` isn't on the network at all. To tell "never
associates" from "associates but no DHCP", read the router log (System Log
export from the web UI) for `joins in 2.4G Wlan` / `DHCPD` lines with its MAC —
but the MR600 does not log failed associations, so silence proves little. See
`docs/router-debugging.md`.

## Onboarding without the app

The bulb must be factory-reset (power off/on 5×) so it broadcasts its open
setup AP. Then:

```bash
.agents/skills/lifx-onboarding/scripts/onboard.sh scan   # what the bulb sees; changes nothing
.agents/skills/lifx-onboarding/scripts/onboard.sh set    # sends SSID + PSK of the current connection
```

- framework only has WiFi: while the script runs, **the session has no
  network** (Claude API, SSH, tailscale). The script rejoins the previous
  connection on exit; if it prints `FAILED to rejoin`, the user has to fix it.
- `set` sends the current connection's PSK to the bulb (read from
  NetworkManager, never printed). It is a separate, outward step from `scan` —
  ask before running it. Run it while connected to the **2.4 GHz** network: the
  5 GHz one has its own SSID the bulb can't see. Override with
  `WIFI_SSID=… WIFI_SEC=…` if needed; `WIFI_SEC` defaults to 5 (WPA2-AES), use
  the value `scan` reports.
- Expect the bulb on the LAN after ~1 minute — `find` at 40 s came up empty on
  2026-11-17, at ~65 s it was there.
- A reset wipes the label: set it back with `lifx.py label`. Home Assistant
  identifies LIFX bulbs by MAC, so the old entity comes back on its own; reload
  the LIFX integration if it stays unavailable.

The SetAccessPoint (305) reply was type 308, which we never decoded; success is
the bulb showing up in `find`, not the reply.

## Why the app failed (2026-11-17, unconfirmed)

The bulb saw the 2.4 GHz network as WPA2-AES with the best signal and joined
with the same PSK as soon as `set` sent it, so router, PSK and bulb were fine.
Likely candidates: the phone leaving the internet-less setup AP before the app
sent the credentials (Android auto-switch / iOS Wi-Fi Assist), or the app
sending the 5 GHz SSID. Not narrowed down further.
