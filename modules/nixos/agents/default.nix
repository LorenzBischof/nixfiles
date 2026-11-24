# Claude Code and Codex for every user on the host, configured through
# wrappers rather than home-manager (see ./wrappers.nix).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.my.programs.agents;
  llmAgents = import ../../../packages/llm-agents.nix { inherit inputs pkgs; };

  wrappers = pkgs.callPackage ./wrappers.nix {
    claude-code = llmAgents.claude-code;
    codex = llmAgents.codex;
    skillPackages = [
      (pkgs.callPackage ../../../packages/agent-skills { inherit (cfg) browser; })
      llmAgents.herdr-core
    ];
    inherit (cfg) mcpServers plugins;
    claudeSettings = cfg.claude.settings;
    claudeFlagSettings = { };
    codexConfig = cfg.codex.config;
    codexOwnedSettings = cfg.codex.ownedSettings;
  };
in
{
  imports = [ ./basic-memory ];

  options.my.programs.agents = {
    enable = lib.mkEnableOption "Claude Code and Codex with a shared skill and plugin set";
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = "MCP servers in Claude's .mcp.json shape; translated for Codex.";
    };
    browser = lib.mkOption {
      type = lib.types.package;
      default = pkgs.chromium;
      defaultText = lib.literalExpression "pkgs.chromium";
      description = "Browser that playwright-cli drives.";
    };
    plugins = lib.mkOption {
      type = with lib.types; attrsOf (either path (attrsOf (nullOr path)));
      default = { };
      description = ''
        Plugins registered under `<name>@nixos`: one directory for both
        harnesses, or `{ claude, codex }` with one each (null to skip one).
      '';
    };
    claude.settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Top-level keys of ~/.claude/settings.json that Nix owns: the wrapper
        replaces each one at launch and leaves the rest of the file alone.
      '';
    };
    codex.config = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Codex config.toml settings for this host, passed as `-c` flags.";
    };
    codex.ownedSettings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = ''
        JSON files under ~/.codex -> their top-level keys that Nix owns, merged
        at launch the way claude.settings is.
      '';
    };
    wrappers = lib.mkOption {
      readOnly = true;
      internal = true;
      default = wrappers;
      description = "The claude and codex wrappers, for `.override` by sandboxing wrappers.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      wrappers.claude
      wrappers.codex
      # Agents reach for python3 for one-off scripting; without it they fall
      # back to awk and sed, which is where the fiddly mistakes come from.
      pkgs.python3
    ];
    my.programs.agents = {
      plugins.egm = inputs.egm;
      claude.settings = lib.mapAttrs (_: lib.mkDefault) {
        attribution = {
          commit = "";
          pr = "";
        };
        spinnerVerbs = {
          mode = "replace";
          verbs = [ "Working" ];
        };
        spinnerTipsEnabled = false;
        prefersReducedMotion = true;
        feedbackSurveyRate = 0;
        statusLine = {
          type = "command";
          command = lib.getExe (pkgs.callPackage ./claude-statusline.nix { });
        };
        # After 5 auto-mode denials Claude Code opens a "Teach auto mode about
        # your environment?" dialog, which blocks an agent in an hc terminal
        # until someone answers it. "off" turns the whole setup feature off.
        skillOverrides."auto-mode-setup" = "off";
      };
      codex.config.tui.animations = lib.mkDefault false;
    };
  };
}
