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
  llmAgents = pkgs.llm-agents;

  # Orca's own skills are stubs that load the version-matched guide from the
  # orca executable at runtime. `skills install` writes them the way the app's
  # "Update skills" does, without a network or a running Orca.
  orcaSkills = pkgs.runCommand "orca-skills" { nativeBuildInputs = [ llmAgents.orca ]; } ''
    export HOME=$TMPDIR
    orca skills install --skill orca-cli --skill orchestration --agent universal
    mkdir -p $out/share/skills
    cp -r $HOME/.agents/skills $out/share/skills/orca
  '';

  wrappers = pkgs.callPackage ./wrappers.nix {
    claude-code = llmAgents.claude-code;
    inherit (pkgs) codex;
    skillPackages = [
      (pkgs.callPackage ../../../packages/agent-skills { inherit (cfg) browser; })
    ];
    inherit (cfg) orchestratorSkills mcpServers plugins;
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
    orchestratorSkills = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.package);
      default = { };
      description = ''
        Skill packages loaded only inside that terminal app: `orca` in an Orca
        terminal, `hc` everywhere else. Each app's agents use its own
        orchestrator, and the other's skills would only compete with it.
      '';
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
      description = "The agent wrappers, for `.override` by sandboxing wrappers.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      wrappers.claude
      wrappers.claude-auto
      wrappers.codex
      # Agents reach for python3 for one-off scripting; without it they fall
      # back to awk and sed, which is where the fiddly mistakes come from.
      pkgs.python3
    ];
    my.programs.agents = {
      plugins.egm = inputs.egm;
      orchestratorSkills = {
        hc = [ llmAgents.herdr-core ];
        orca = [ orcaSkills ];
      };
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
        # After 5 auto-mode denials Claude Code opens a "Teach auto mode about
        # your environment?" dialog, which blocks an agent in an hc terminal
        # until someone answers it. "off" turns the whole setup feature off.
        skillOverrides."auto-mode-setup" = "off";
        # Entries are prose rules for the classifier. Keep each one short and
        # simple, and add one only for a block that actually happened: they
        # tend to grow long and complicated. Name what the classifier can see
        # in the command (branch names, URLs), and give an allow entry its
        # reason. A list without "$defaults" drops the built-in rules, and an
        # allow entry overrides the built-in blocks, so keep allow entries
        # narrow. Before deploying, run `claude --settings FILE auto-mode
        # critique` once, for ambiguity and redundancy; its suggestions to add
        # more are rarely worth taking.
        autoMode = {
          environment = [
            "$defaults"
            "Source control: github.com/lorenzbischof-agents is the user's org of forks, each with its upstream's visibility."
          ];
          allow = [
            "$defaults"
            "Force-pushing a branch other than main or master to a repository under github.com/lorenzbischof-agents is allowed: only agents work on those branches."
          ];
        };
      };
      codex.config.tui.animations = lib.mkDefault false;
    };
  };
}
