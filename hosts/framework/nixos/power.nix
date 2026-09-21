# Panel power tuning, on battery only.
#
# Re-measuring anything here: compare against a control run of the identical
# state minutes earlier, never against a number from another session. The idle
# floor drifts ~0.1 W between runs (that is the noise floor), and an animated
# TUI in a terminal -- a progress spinner -- costs ~0.4 W on its own, enough to
# invert a result.
{ pkgs, ... }:
let
  # Adaptive backlight modulation: the panel lowers its backlight and
  # compensates with pixel gain. The saving scales with backlight power:
  # -0.11 W at the low backlight used day to day, -0.14 W at 50%, -0.45 to
  # -0.6 W at full brightness. Level 2 is not noticeable on this panel. Off on
  # AC, where the tradeoff buys nothing.
  abmLevel = 2;

  panelAbm = pkgs.writeShellScript "panel-abm" ''
    set -eu
    # Treat an unreadable ACAD as AC: never leave the panel dimmed because of a
    # sysfs hiccup.
    if [ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null || echo 1)" = 1 ]; then
      level=0
    else
      level=${toString abmLevel}
    fi
    # The card number is not stable across boots, and the attribute only exists
    # once amdgpu has probed the eDP connector, so glob rather than hardcode.
    for f in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
      [ -e "$f" ] || continue
      echo "$level" > "$f"
    done
  '';
in
{
  systemd.services.panel-abm = {
    description = "Set panel adaptive backlight modulation from AC state";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = panelAbm;
    };
  };

  # Re-apply on every mains plug/unplug, and when amdgpu registers the card at
  # boot (the boot-time oneshot otherwise races the driver and finds no
  # attribute). `start`, not `restart`, for the same reason as npu-pmode in
  # ai.nix: a plug event storm should queue, not kill an in-flight write.
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="${pkgs.systemd}/bin/systemctl --no-block start panel-abm.service"
    SUBSYSTEM=="drm", KERNEL=="card[0-9]", ACTION=="add", RUN+="${pkgs.systemd}/bin/systemctl --no-block start panel-abm.service"
  '';

  # Measured and rejected, so they don't get retried blind:
  #
  # ABM level 3. Nothing over level 2, even at full brightness where ABM has
  # the most headroom: +0.05 W in one half of an interleaved run and -0.07 W in
  # the other, against 0.11-0.18 W of between-block scatter. Also why
  # power-profiles-daemon's amdgpu_panel_power action is no substitute: its
  # level is not configurable, it ladders by battery percentage, and it only
  # reaches 3 below 20% charge.
  #
  # Re-applying the level on resume. The attribute survives s2idle, DPMS off/on
  # and hibernate. It is backed by amdgpu's connector state, not a hardware
  # readback, so hibernate was checked by measurement instead: still -0.45 W
  # against level 0 on restore.
  #
  # Panel self-refresh. nixos-hardware disables it for every FW13 AMD with
  # amdgpu.dcdebugmask=0x10, citing a 2024 hang report against the 7040
  # generation (drm/amd#3647). Overriding that here measured -0.06 W, inside
  # the noise floor -- not worth carrying a workaround's workaround. It buys
  # nothing because sway sets adaptive_sync on (modules/home/wayland), which
  # already parks the panel at its minimum refresh on a static screen; PSR is
  # solving a problem VRR has already solved. Don't retry without VRR off.
  #
  # Capping eDP at 60 Hz on battery: nothing (5.05 W vs 5.03 W). Same reason --
  # the max rate only applies while something is actually moving.
  #
  # PCIe ASPM. The on-die links (iGPU, NPU, all six USB controllers) have L1
  # off, and enabling it per device via /sys/.../link/l1_aspm did not take on a
  # single one of them -- apparently not allowed while the policy stays at the
  # firmware default -- so the only route left is pcie_aspm.policy=. Left alone:
  # on this exact model that makes the MT7925 vanish with "driver own failed"
  # until a full power-off -- reboots do not clear it.
  # https://community.frame.work/t/83690
}
