{ lib, pkgs, ... }:

{
  services.open-webui.enable = false;
  services.llama-cpp = {
    enable = true;
    package = pkgs.llama-cpp-vulkan;
    settings = {
      flash-attn = "on";
      split-mode = "row";
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
}
