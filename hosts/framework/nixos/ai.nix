{
  config,
  lib,
  pkgs,
  ...
}:
let
  xrtSmi = "${config.environment.sessionVariables.XILINX_XRT}/bin/xrt-smi";
  # The NPU power mode is a device-global XRT setting, not a per-process one,
  # and flm's own --pmode flag is a silent no-op for a normal user: it needs
  # DRM_IOCTL_AMDXDNA_SET_STATE, which returns EACCES even for @video members
  # with rw on /dev/accel/accel0, and flm neither logs nor reports the failure.
  # So set it from root here instead, following AC state. Measured on
  # Qwen3.6-35B-A3B: powersaver is 7.5 tok/s at ~0.15 J/token, performance is
  # 14.1 tok/s at ~0.30 J/token -- the clocks drop faster than the throughput,
  # so powersaver genuinely saves energy rather than just stretching the work.
  # `turbo` is deliberately unused: it needs AC and silently falls back to
  # performance on battery.
  npuPmode = pkgs.writeShellScript "npu-pmode" ''
    set -eu
    dev=$(${xrtSmi} examine 2>/dev/null \
      | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | head -1)
    # No NPU enumerated (driver not up yet, or no device): nothing to do.
    [ -n "$dev" ] || exit 0
    if [ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null || echo 0)" = 1 ]; then
      mode=performance
    else
      mode=powersaver
    fi
    # Only ever issue SET_STATE when the mode actually has to change. Plugging
    # in emits several ACAD uevents, and each redundant ioctl is another chance
    # to hit the amdxdna mailbox teardown path, which NULL-derefs if its
    # workqueue allocation fails. Cheap read, and it collapses an event storm
    # into a single write.
    current=$(${xrtSmi} examine -r platform -d "$dev" 2>/dev/null \
      | sed -n 's/.*Power Mode[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' | head -1)
    [ "$current" != "$mode" ] || exit 0
    exec ${xrtSmi} configure -d "$dev" --pmode "$mode"
  '';
in

{
  services.open-webui.enable = false;
  services.llama-cpp = {
    enable = true;
    package = pkgs.llama-cpp-vulkan;
    settings = {
      flash-attn = "on";
      # No split-mode: this host has a single Vulkan device, so "row" (which
      # splits tensors across devices) buys nothing, and the Vulkan backend
      # never implemented split buffers. Recent llama.cpp turns that into a
      # hard "device Vulkan0 does not support split buffers" failure as soon as
      # `fit = on` spills a large model across GPU + CPU.
      # https://github.com/ggml-org/llama.cpp/issues/25884
      no-context-shift = true;
      models-preset = pkgs.writeText "llama-models.ini" (
        lib.generators.toINI { } {
          "qwen3-coder" = {
            hf-repo = "unsloth/Qwen3-Coder-Next-GGUF";
            hf-file = "Qwen3-Coder-Next-UD-Q4_K_XL.gguf";
            alias = "qwen3-coder";
            fit = "on";
            jinja = "on";
            ctx-size = "32768";
            temp = "1.0";
            top-p = "0.95";
            top-k = "40";
            min-p = "0";
          };
          "gemma4" = {
            hf-repo = "unsloth/gemma-4-26B-A4B-it-GGUF:Q8_0";
            alias = "gemma4";
            fit = "on";
            jinja = "on";
            ctx-size = "32768";
            ubatch-size = "1024";
            image-min-tokens = "256";
            image-max-tokens = "512";
            temp = "1.0";
            top-p = "0.95";
            top-k = "64";
          };
          # Same weights FLM serves on the NPU (qwen3.6-moe:35b-a3b), at a
          # comparable bit width (21G NPU2 dir vs 22G Q4_K_XL), so iGPU and NPU
          # throughput can be compared directly. Sampling params are Qwen's
          # recommended thinking-mode set for general tasks.
          "qwen3.6" = {
            hf-repo = "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL";
            alias = "qwen3.6";
            fit = "on";
            jinja = "on";
            ctx-size = "32768";
            temp = "1.0";
            top-p = "0.95";
            top-k = "20";
            min-p = "0";
            presence-penalty = "1.5";
            # No `reasoning` setting on purpose: llama.cpp's default (auto,
            # detect from template) makes Qwen3.6 think, and FLM also thinks by
            # default on streaming requests, which is all pi sends. Pinning
            # `reasoning = "off"` here would make the iGPU the only non-thinking
            # side and skew any comparison against the NPU.
          };
          "qwen3-vl-2b" = {
            hf-repo = "Qwen/Qwen3-VL-2B-Instruct-GGUF";
            alias = "qwen3-vl-2b";
            fit = "on";
            jinja = "on";
            ctx-size = "32768";
            temp = "0.7";
            top-p = "0.8";
            top-k = "20";
            min-p = "0";
          };
          "qwen3-vl-4b" = {
            hf-repo = "Qwen/Qwen3-VL-4B-Instruct-GGUF";
            alias = "qwen3-vl-4b";
            fit = "on";
            jinja = "on";
            ctx-size = "32768";
            temp = "0.7";
            top-p = "0.8";
            top-k = "20";
            min-p = "0";
          };
          "qwen3-4b" = {
            hf-repo = "unsloth/Qwen3-4B-Instruct-2507-GGUF";
            alias = "qwen3-4b";
            fit = "on";
            jinja = "on";
            ctx-size = "32768";
            temp = "0.7";
            top-p = "0.8";
            top-k = "20";
            min-p = "0";
          };
        }
      );
    };
  };
  # Work around llama-cpp-vulkan trying to create //.cache for shader cache:
  # https://github.com/NixOS/nixpkgs/issues/441531
  systemd.services.llama-cpp.environment.XDG_CACHE_HOME = "/var/cache/llama-cpp";

  # Ryzen AI NPU (XDNA2). The module loads amdxdna, installs XRT + FastFlowLM
  # and grants /dev/accel + unlimited memlock to @video/@render. llama-cpp above
  # keeps the iGPU: the NPU decodes at roughly iGPU speed while drawing a
  # fraction of the power, and the two run concurrently without the iGPU losing
  # throughput — a second engine, not a faster one. The model it serves is set
  # by the flm user service in hosts/framework/home.
  hardware.amd-npu = {
    enable = true;
    enableNPU = true;
    enableFastFlowLM = true;
    # Lemonade only adds a router in front of FLM, and llama-cpp already serves
    # the GPU side, so keep those halves out of the closure.
    enableLemonade = false;
    enableROCm = false;
    enableVulkan = false;
    enableImageGen = false;
  };

  # Follow AC state: powersaver on battery, performance on mains. Re-run on
  # every mains plug/unplug, and when the NPU itself shows up at boot (the
  # oneshot can otherwise race amdxdna and find no device to configure).
  systemd.services.npu-pmode = {
    description = "Set Ryzen AI NPU power mode from AC state";
    wantedBy = [ "multi-user.target" ];
    # xrt-smi sources a setup.sh that shells out to awk; without it the unit
    # still works but logs "awk: command not found" on every run.
    path = [ pkgs.gawk ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = npuPmode;
    };
  };

  # `start`, never `restart`: restart stops any in-flight run first, and a
  # SIGTERM delivered while xrt-smi sits inside the amdxdna SET_STATE ioctl
  # made kthread_create return -EINTR, which the driver did not check --
  # NULL deref, kernel oops, frozen machine (2026-09-20). `start` queues
  # instead of killing.
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="${pkgs.systemd}/bin/systemctl --no-block start npu-pmode.service"
    SUBSYSTEM=="accel", ACTION=="add", RUN+="${pkgs.systemd}/bin/systemctl --no-block start npu-pmode.service"
  '';
}
