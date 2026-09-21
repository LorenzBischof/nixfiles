# Pause the configured libvirt guests while nothing talks to them; resume on
# first access. Event-driven: the daemon blocks on a conntrack event stream
# rather than polling anything.

NETWORK="${NETWORK:?}"
# Addresses to keep wakeable that libvirt does not declare -- see pin_neigh.
WAKE_ADDRS="${WAKE_ADDRS:-}"
IDLE_SECS="${IDLE_SECS:-300}"
SLEEP_ON_AC="${SLEEP_ON_AC:-0}"
DOMAINS="${DOMAINS:-}"

virsh() { command virsh -c qemu:///system "$@"; }

# Topology is read from libvirt rather than copied from wherever the guests are
# defined. A hand-copied snapshot fails silently when it drifts -- it keeps
# watching addresses that no longer matter and stops waking the ones that do --
# whereas discovery that comes up empty exits into the journal.
net_xml=$(virsh net-dumpxml "$NETWORK") || exit 1
BRIDGE=$(sed -n "s/.*<bridge name='\([^']*\)'.*/\1/p" <<<"$net_xml")
RESERVATIONS=$(sed -n "s/.*<host mac='\([^']*\)' name='[^']*' ip='\([^']*\)'.*/\2=\1/p" <<<"$net_xml")
# DHCP reservation names are libvirt domain names only by convention, and this
# network also carries reservations that are no domain at all -- the floating
# service VIPs among them. Keep only what libvirt actually defines: a stray name
# suspends nothing (vms() swallows the error) and, if it sorts first, makes the
# state recovery below read a domain that does not exist, which leaves paused
# guests unpinned and unwakeable.
if [ -z "$DOMAINS" ]; then
  defined=" $(virsh list --all --name | tr '\n' ' ')"
  while read -r name; do
    [[ $defined == *" $name "* ]] && DOMAINS+="$name "
  done < <(sed -n "s/.*<host mac='[^']*' name='\([^']*\)'.*/\1/p" <<<"$net_xml")
fi
: "${BRIDGE:?no bridge found in network $NETWORK}" \
  "${DOMAINS:?no guests found in network $NETWORK}"

# Match the subnet, not a list of addresses: service VIPs are handed out from a
# pool inside it, so naming individual addresses silently misses all but the
# first. Keeping the filter in conntrack's own code also means unrelated
# connections (docker, tailscale, the browser) never reach this process.
WAKE_CIDR=$(ip -o -4 route show dev "$BRIDGE" scope link | awk '{print $1; exit}')
: "${WAKE_CIDR:?no route on $BRIDGE}"

# Destination alone is the wrong question: br_netfilter conntracks bridged
# traffic, so the guests talking to each other match it too, and worker-0's
# kubelet reconnecting to cp-0 on 6443 never stops -- counting that as activity
# is enough on its own to keep the idle timer from ever expiring.
#
# The initiator is what matters, and on a NAT network there are only two of
# them. Nothing off this laptop can route into the subnet, so an event either
# comes from a guest or from this host, which reaches the guests with the bridge
# address as its source (ip route get 10.69.0.10 -> src 10.69.0.1). Naming that
# source is the whole direction test, and conntrack applies it in kernel rather
# than this process re-deciding it per event.
#
# It also leaves no port policy to express: a TCP connection from this laptop
# into the guest subnet is use of the cluster whatever port it lands on. The
# port list this replaces was worse than redundant -- it was a comma list in a
# systemd Environment=, which splits on whitespace, so it had silently arrived
# as just its first entry.
HOST_IP=$(ip -o -4 addr show dev "$BRIDGE" | awk '{sub(/\/.*/, "", $4); print $4; exit}')
: "${HOST_IP:?no address on $BRIDGE}"

# An unmatched glob stays literal, so without the readability test this silently
# decides the machine is never on AC -- which inverts SLEEP_ON_AC=0 into pausing
# the guests while plugged in.
for f in /sys/class/power_supply/A*/online; do [ -r "$f" ] && AC_ONLINE=$f && break; done
: "${AC_ONLINE:?no AC power supply found}"
on_ac() { local o; read -r o <"$AC_ONLINE" 2>/dev/null && [ "$o" = 1 ]; }

# A paused guest cannot answer ARP, and an unresolved address fails connect()
# with EHOSTUNREACH instead of emitting the SYN that would wake it. Pin the
# declared reservations, and promote whatever else the bridge has already
# resolved.
#
# Floating service VIPs are the gap that leaves: libvirt does not declare them
# (they are elected at runtime, so they have no reservation to read), and
# promotion only helps if the address happens to be in the neighbour cache
# already -- which after a restart it is not. An ingress hostname is the likeliest
# way anything here touches the cluster, so that gap means the common path cannot
# wake it. WAKE_ADDRS names those addresses, and any guest MAC serves to pin one:
# the frame only has to leave the host for conntrack to see the connection and
# resume, and whichever guest actually holds the VIP answers once resumed, by
# which time resume_vms has dropped the pin again.
ANY_MAC=${RESERVATIONS%%$'\n'*}
ANY_MAC=${ANY_MAC##*=}
for addr in $WAKE_ADDRS; do RESERVATIONS+=$'\n'"$addr=$ANY_MAC"; done

PINNED=""
pin_neigh() {
  local entry addr mac
  for entry in $RESERVATIONS $(ip neigh show dev "$BRIDGE" | awk '$2=="lladdr"{print $1"="$3}'); do
    addr=${entry%%=*}
    mac=${entry##*=}
    ip neigh replace "$addr" lladdr "$mac" dev "$BRIDGE" nud permanent 2>/dev/null &&
      PINNED+=" $addr"
  done
}
unpin_neigh() {
  local addr
  for addr in $PINNED; do ip neigh del "$addr" dev "$BRIDGE" 2>/dev/null; done
  PINNED=""
}

vms() { local d; for d in $DOMAINS; do virsh "$1" "$d" >/dev/null 2>&1; done; }

suspend_vms() {
  echo "idle ${IDLE_SECS}s -> suspending"
  pin_neigh
  # Back-to-back with no work between: if the guests drift apart in time the
  # worker misses its node lease and the control plane starts evicting.
  vms suspend
  paused=1
}

resume_vms() {
  echo "wake ($1) -> resuming"
  vms resume
  unpin_neigh
  paused=0
}

open_stream() { exec 3< <(conntrack -E -e NEW -p tcp -s "$HOST_IP" -d "$WAKE_CIDR"); }

trap unpin_neigh EXIT

# Recover state across a restart, pins included: a previous exit unpinned them,
# and a paused guest with no neighbour entry can never be woken.
case "$(virsh domstate "${DOMAINS%% *}" 2>/dev/null)" in
  paused) paused=1; pin_neigh ;;
  *) paused=0 ;;
esac
last_activity=$EPOCHSECONDS
backoff=1
open_stream
echo "armed: network=$NETWORK bridge=$BRIDGE cidr=$WAKE_CIDR guests=${DOMAINS}idle=${IDLE_SECS}s paused=$paused"

while true; do
  # Waking is driven by the event stream, not by this tick, so the tick only
  # paces the decision below: the idle timer while running, and an AC change
  # while paused -- which matters only if SLEEP_ON_AC is overridden back to 0.
  if [ "$paused" = 1 ]; then tick=5; else tick=30; fi

  # The content no longer matters, only that an event arrived, so read discards it.
  read -r -t "$tick" -u 3
  rc=$?

  if [ "$rc" = 0 ]; then
    # Every event that survives conntrack's filter is this host reaching into the
    # guest subnet, so there is nothing left to match on the line itself.
    backoff=1
    last_activity=$EPOCHSECONDS
    [ "$paused" = 1 ] && resume_vms traffic
  elif [ "$rc" -le 128 ]; then
    # conntrack exited (module missing, no privilege, ENOBUFS). Reopening in a
    # tight loop costs a whole core and never trips Restart=, so back off.
    echo "conntrack stream ended; reopening in ${backoff}s"
    sleep "$backoff"
    ((backoff < 30)) && backoff=$((backoff * 2))
    open_stream
  fi

  # Decided every iteration rather than only when the read times out. Hanging it
  # off the timeout means any stream busier than one event per tick starves it
  # entirely -- not merely delays it -- and the idle timer is then unreachable no
  # matter how long ago the last connection was. That is how this went a month
  # without ever pausing once.
  if on_ac && [ "$SLEEP_ON_AC" != "1" ]; then
    last_activity=$EPOCHSECONDS
    [ "$paused" = 1 ] && resume_vms "on AC"
  elif [ "$paused" = 0 ] && ((EPOCHSECONDS - last_activity >= IDLE_SECS)); then
    suspend_vms
  fi
done
