"""Talk to LIFX bulbs over the LAN protocol (UDP/TLS port 56700), stdlib only.

lifx.py find [PREFIX]        list bulbs in PREFIX.1-254 (default 192.168.0) with labels
lifx.py label IP [NEW]       read or set a bulb's label
lifx.py scan IP              soft-AP only: list the networks the bulb can see
lifx.py set IP               soft-AP only: send WIFI_SSID / WIFI_PSK / WIFI_SEC from env
"""

import os, socket, ssl, struct, sys, time

PORT = 56700
SEC = {
    1: "open",
    2: "WEP",
    3: "WPA-TKIP",
    4: "WPA-AES",
    5: "WPA2-AES",
    6: "WPA2-TKIP",
    7: "WPA2-mixed",
}
GET_LABEL, SET_LABEL, STATE_LABEL = 23, 24, 25
GET_APS, SET_AP, STATE_AP = 304, 305, 306


def pkt(t, payload=b""):
    # tagged + addressable, protocol 1024, res_required
    return (
        struct.pack(
            "<HHI8s6sBBQHH",
            36 + len(payload),
            0x3400,
            0x4C49,
            b"\0" * 8,
            b"\0" * 6,
            0x01,
            1,
            0,
            t,
            0,
        )
        + payload
    )


def frames(buf):
    out = []
    while len(buf) >= 36:
        size = struct.unpack("<H", buf[:2])[0]
        if size < 36 or len(buf) < size:
            break
        out.append((struct.unpack("<H", buf[32:34])[0], buf[36:size]))
        buf = buf[size:]
    return out


def cstr(b):
    return b.split(b"\0", 1)[0].decode(errors="replace")


def udp(dests, data, want, wait=2.0):
    """Send one datagram to each dest; collect (src_ip, payload) replies of type `want`.

    Unicast on purpose: replies to a broadcast don't match a conntrack entry,
    so the NixOS firewall on framework drops them.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # sweeping a /24 overflows the unresolved-ARP queue; the second round
    # reaches hosts that got resolved during the first
    for rnd in range(2 if len(dests) > 1 else 1):
        for dest in dests:
            try:
                s.sendto(data, (dest, PORT))
            except OSError:
                pass
        if rnd == 0 and len(dests) > 1:
            time.sleep(1)
    s.settimeout(0.3)
    res, end = [], time.time() + wait
    while time.time() < end:
        try:
            d, (src, _) = s.recvfrom(4096)
        except socket.timeout:
            continue
        res += [(src, p) for t, p in frames(d) if t == want and src in dests]
    return res


def tls(ip, data, wait=6.0):
    """Onboarding messages go over TLS on TCP 56700; the bulb's cert is self-signed."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_ciphers("ALL:@SECLEVEL=0")
    s = ctx.wrap_socket(socket.create_connection((ip, PORT), timeout=5))
    s.sendall(data)
    s.settimeout(1)
    buf, end = b"", time.time() + wait
    while time.time() < end:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
    return frames(buf)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "find":
        prefix = args[0] if args else "192.168.0"
        seen = {}
        for src, p in udp(
            [f"{prefix}.{i}" for i in range(1, 255)],
            pkt(GET_LABEL),
            STATE_LABEL,
            wait=3,
        ):
            seen[src] = cstr(p[:32])
        for ip in sorted(seen, key=lambda a: tuple(map(int, a.split(".")))):
            print(f"{ip:15} {seen[ip]}")
        if not seen:
            print("no bulbs answered")
    elif cmd == "label":
        ip = args[0]
        data = (
            pkt(SET_LABEL, struct.pack("<32s", args[1].encode()))
            if len(args) > 1
            else pkt(GET_LABEL)
        )
        for attempt in range(3):
            res = udp([ip], data, STATE_LABEL)
            if res:
                print(ip, cstr(res[0][1][:32]))
                return
        sys.exit(f"{ip}: no reply")
    elif cmd == "scan":
        for t, p in tls(args[0], pkt(GET_APS), wait=8):
            if t == STATE_AP and len(p) >= 38:
                _iface, ssid, sec, strength, _chan = struct.unpack("<B32sBhH", p[:38])
                print(f"{cstr(ssid):32} {SEC.get(sec, sec):11} strength={strength}")
    elif cmd == "set":
        ssid, psk = os.environ["WIFI_SSID"].encode(), os.environ["WIFI_PSK"].encode()
        sec = int(os.environ.get("WIFI_SEC", "5"))
        # interface 2 = station
        payload = struct.pack("<B32s64sB", 2, ssid, psk, sec)
        types = [t for t, _ in tls(args[0], pkt(SET_AP, payload), wait=4)]
        print(
            f"SetAccessPoint sent: ssid={ssid.decode()} security={SEC.get(sec, sec)} replies={types}"
        )
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
