{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  cfg = config.my.profiles.ai;
  baseCodex = inputs.llm-agents.packages.${pkgs.system}.codex;
  codexNotifyConfigArg = "notify=[\"${lib.getExe codexNotify}\"]";
  codexNotify = pkgs.writeShellScriptBin "codex-notify" ''
    set -eu
    payload="''${1:-}"
    [ -n "$payload" ] || exit 0

    # Keep behavior stable if codex adds more events: only notify for agent-turn-complete.
    printf '%s' "$payload" | ${lib.getExe pkgs.jq} -e '.type == "agent-turn-complete"' >/dev/null 2>&1 || exit 0

    ${lib.optionalString cfg.codexNotify.bell.enable ''
      if [ -t 1 ]; then
        printf '\a' || true
      fi
    ''}
  '';
  wrappedCodex = pkgs.writeShellScriptBin "codex" ''
    exec ${lib.getExe baseCodex} -c ${lib.escapeShellArg codexNotifyConfigArg} ${lib.escapeShellArgs cfg.codexArgs} "$@"
  '';
  renderedAgentsMd = builtins.readFile cfg.agentsFile;
in
{
  imports = [
    ./aichat.nix
  ];
  options.my.profiles.ai = {
    enable = lib.mkEnableOption "ai";
    codexArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "CLI arguments passed to codex by the wrapper package.";
      default = [
        "-s"
        "workspace-write"
        "-a"
        "untrusted"
        "-c"
        "sandbox_workspace_write.network_access=true"
        "-c"
        "tui.animations=false"
      ];
    };
    agentsFile = lib.mkOption {
      type = lib.types.path;
      default = ./AGENTS.md;
      description = "Source AGENTS.md file for AI tools.";
    };
    codexNotify = {
      bell.enable = (lib.mkEnableOption "terminal bell for Codex notifications") // {
        default = true;
      };
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [
      inputs.mcp-nixos.packages.${pkgs.system}.default
      pkgs.nil
      #inputs.nix-ai-tools.packages.${pkgs.system}.openclaw
    ];
    services.ollama = {
      enable = true;
      package = pkgs.ollama-vulkan;
      environmentVariables = {
        OLLAMA_CONTEXT_LENGTH = "20000";
        OLLAMA_KEEP_ALIVE = "20m";
      };
    };

    programs.opencode = {
      enable = true;
      package = inputs.llm-agents.packages.${pkgs.system}.opencode;
    };

    programs.claude-code = {
      enable = true;
      package = inputs.llm-agents.packages.${pkgs.system}.claude-code;
    };

    programs.codex = {
      enable = true;
      package = wrappedCodex;
    };

    # Global Claude Code context file
    home.file.".claude/CLAUDE.md".text = renderedAgentsMd;

    # Global Codex context file
    home.file.".codex/AGENTS.md".text = renderedAgentsMd;

    # Nix documentation skill
    home.file.".claude/skills/nix-docs/SKILL.md".source = ./skills/nix-docs/SKILL.md;
  };
}
