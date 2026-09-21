{ lib, pkgs, ... }:

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
}
