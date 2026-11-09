#!/usr/bin/env bash
# usage: onboard.sh scan|set [BULB_AP_SSID]
# Joins the bulb's setup AP, runs `lifx.py scan|set` against it, and always
# rejoins the WiFi connection that was active before.
set -u
mode=${1:?usage: onboard.sh scan|set [BULB_AP_SSID]}
dir=$(dirname "$(readlink -f "$0")")
ifname=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi" {print $1; exit}')
home_con=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$ifname" '$2==d {print $1; exit}')
[ -n "$home_con" ] || { echo "no active wifi connection on $ifname" >&2; exit 1; }

bulb_ap=${2:-$(nmcli -t -f SSID dev wifi list --rescan yes | grep -m1 '^LIFX')}
[ -n "$bulb_ap" ] || { echo "no LIFX setup AP visible — is the bulb reset?" >&2; exit 1; }

if [ "$mode" = set ]; then
  # SSID defaults to the connection we are on; the PSK never leaves this process tree
  export WIFI_SSID=${WIFI_SSID:-$(nmcli -g 802-11-wireless.ssid con show "$home_con")}
  export WIFI_PSK=$(nmcli -s -g 802-11-wireless-security.psk con show "$home_con")
fi

cleanup() {
  nmcli con delete "$bulb_ap" >/dev/null 2>&1
  if nmcli con up "$home_con" >/dev/null 2>&1; then echo "== back on $home_con"
  else echo "!! FAILED to rejoin $home_con — run: nmcli con up '$home_con'"; fi
}
trap cleanup EXIT

echo "== joining $bulb_ap (from $home_con on $ifname)"
nmcli dev wifi connect "$bulb_ap" ifname "$ifname" >/dev/null || exit 1
sleep 3
gw=$(ip -4 route show dev "$ifname" | awk '/default/ {print $3; exit}')
gw=${gw:-172.16.0.1}
echo "== bulb at $gw"
python3 -I -W ignore "$dir/lifx.py" "$mode" "$gw"
