# Pause idle libvirt guests to save battery, and wake them on first access.
#
# An idle guest workload is often not actually idle: these guests burn most of
# a host core and the large majority of this laptop's interrupts on heartbeat
# traffic that never stops. Pausing them takes that to zero; resuming has them
# answering again in tens of milliseconds, because it unpauses vCPUs rather
# than booting anything.
#
# Wake path, and why there is no proxy: the daemon blocks on a conntrack event
# stream and sees any new connection this host opens toward the guest subnet.
# Nothing is intercepted, redirected or TLS-terminated -- a paused guest simply
# does not answer the first SYN, and TCP retransmits until it does, so client
# config and certificates keep working untouched. The same stream drives the
# sleep half: no event for IDLE_SECS means nothing here is using the guests.
#
# Only connections this host initiates count. The guests gossip among themselves
# constantly and the bridge is conntracked, so watching the subnet without
# pinning the source counts the cluster's own heartbeat as use and nothing ever
# pauses.
{ pkgs, talosIngressVip, ... }:
let
  vm-autosleep = pkgs.writeShellApplication {
    name = "vm-autosleep";
    runtimeInputs = with pkgs; [
      libvirt
      conntrack-tools
      iproute2
      gnused
      gawk
      coreutils
    ];
    # No errexit: the main loop relies on `read -t` returning non-zero on
    # timeout, which is an ordinary tick rather than a failure.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = builtins.readFile ./vm-autosleep.sh;
  };
in
{
  systemd.services.vm-autosleep = {
    description = "Pause idle libvirt guests, resume on access";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];

    serviceConfig = {
      ExecStart = "${vm-autosleep}/bin/vm-autosleep";
      Restart = "on-failure";
      RestartSec = 5;

      # NETWORK is the only topology needed: the guest names, their MACs, the
      # bridge, the subnet to watch and this host's address on it all come from
      # that libvirt network, so they cannot drift out of sync with whatever
      # defines the guests. WAKE_ADDRS is the exception libvirt cannot supply --
      # a VIP owned by whichever guest currently holds it.
      # IDLE_SECS is the quiet time before pausing. SLEEP_ON_AC=1 pauses whatever
      # the power source is: measured on this laptop, a paused guest draws the
      # same as a shut-down one (5.43 W vs 5.51 W, within noise), while a running
      # pair costs 2.6 W -- so there is nothing to trade away by pausing on AC,
      # only heat and fan to save. Set it to 0 to go back to running while
      # plugged in. Override any of these in /etc/vm-autosleep.env.
      Environment = [
        "NETWORK=talos"
        "WAKE_ADDRS=${talosIngressVip}"
        "IDLE_SECS=300"
        "SLEEP_ON_AC=1"
      ];
      EnvironmentFile = "-/etc/vm-autosleep.env";
    };
  };
}
