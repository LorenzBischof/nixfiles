{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  cfg = config.my.profiles.ai;
  system = pkgs.stdenv.hostPlatform.system;
  baseCodex = inputs.llm-agents.packages.${system}.codex;
  baseClaude = inputs.llm-agents.packages.${system}.claude-code;
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
  mkBwrapTool =
    {
      name,
      executable,
      configDirName,
      extraArgs ? [ ],
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        bubblewrap
        coreutils
        git
        gnugrep
        systemd
      ];
      text = ''
        set -euo pipefail

        repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        sandbox_root="$(mktemp -d -t ${name}.XXXXXX)"
        sandbox_home="$sandbox_root/home/${config.home.username}"
        config_source="$HOME/${configDirName}"
        config_target="$sandbox_home/${configDirName}"
        ca_bundle="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        ca_cert_dir="${pkgs.cacert}/etc/ssl/certs"
        nix_daemon_socket_dir="/nix/var/nix/daemon-socket"
        nix_conf_dir="/etc/nix"
        github_token_file="/run/agenix/github-token"
        github_token=""

        cleanup() {
          rm -rf "$sandbox_root"
        }
        trap cleanup EXIT

        mkdir -p "$sandbox_home"

        if [ -r "$github_token_file" ]; then
          github_token="$(grep -oP '(?<=github\.com=)\S+' "$github_token_file" || true)"
        fi

        declare -a bwrap_args=(
          --die-with-parent
          --unshare-all
          --share-net
          --proc /proc
          --dev /dev
          --tmpfs /tmp
          --dir /run
          --dir /etc
          --dir /home
          --ro-bind /nix/store /nix/store
          --ro-bind /run/current-system/sw /run/current-system/sw
          --ro-bind /etc/static /etc/static
          --ro-bind /etc/profiles /etc/profiles
          --ro-bind /etc/resolv.conf /etc/resolv.conf
          --ro-bind /etc/hosts /etc/hosts
          --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf
          --ro-bind "$ca_cert_dir" /etc/ssl/certs
          --bind "$sandbox_home" "$HOME"
          --bind "$repo_root" "$repo_root"
          --chdir "$repo_root"
          --setenv HOME "$HOME"
          --setenv USER "${config.home.username}"
          --setenv PATH "$PATH"
          --setenv SSL_CERT_FILE "$ca_bundle"
          --setenv NIX_SSL_CERT_FILE "$ca_bundle"
          --setenv NIX_REMOTE daemon
        )

        if [ -e "$HOME/.nix-profile" ]; then
          bwrap_args+=(--ro-bind "$HOME/.nix-profile" "$HOME/.nix-profile")
        fi

        if [ -d "$HOME/.local/state/nix/profiles" ]; then
          bwrap_args+=(--ro-bind "$HOME/.local/state/nix/profiles" "$HOME/.local/state/nix/profiles")
        fi

        # Allow sandboxed tools to use the host Nix daemon without exposing the DB.
        if [ -S "$nix_daemon_socket_dir/socket" ]; then
          bwrap_args+=(--bind "$nix_daemon_socket_dir" "$nix_daemon_socket_dir")
        fi

        if [ -d "$nix_conf_dir" ]; then
          bwrap_args+=(--ro-bind "$nix_conf_dir" "$nix_conf_dir")
        fi

        if [ -d "$config_source" ]; then
          mkdir -p "$config_target"
          bwrap_args+=(--bind "$config_source" "$HOME/${configDirName}")
        fi

        if [ -f "$HOME/${configDirName}.json" ]; then
          bwrap_args+=(--bind "$HOME/${configDirName}.json" "$HOME/${configDirName}.json")
        fi

        if [ -n "$github_token" ]; then
          bwrap_args+=(
            --setenv GH_TOKEN "$github_token"
            --setenv GITHUB_TOKEN "$github_token"
          )
        fi

        exec systemd-inhibit \
          --what=sleep \
          --mode=block \
          --why="AI sandbox session" \
          bwrap "''${bwrap_args[@]}" -- ${lib.escapeShellArg executable} ${lib.escapeShellArgs extraArgs} "$@"
      '';
    };
  codexBwrap = mkBwrapTool {
    name = "codex-bwrap";
    executable = lib.getExe baseCodex;
    configDirName = ".codex";
    extraArgs = [
      "-c"
      codexNotifyConfigArg
      "-c"
      "tui.animations=false"
      "--dangerously-bypass-approvals-and-sandbox"
    ];
  };
  claudeBwrap = mkBwrapTool {
    name = "claude-bwrap";
    executable = lib.getExe baseClaude;
    configDirName = ".claude";
    extraArgs = [ "--dangerously-skip-permissions" ];
  };
  renderedAgentsMd = builtins.readFile cfg.agentsFile;
in
{
  imports = [
    ./aichat.nix
    inputs.voxtype.homeManagerModules.default
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
      inputs.mcp-nixos.packages.${system}.default
      pkgs.nil
      codexBwrap
      claudeBwrap
      #inputs.nix-ai-tools.packages.${system}.openclaw
    ];

    programs.voxtype = {
      enable = true;
      package = pkgs.voxtype-vulkan;
      service.enable = true;
      settings = {
        hotkey.enabled = false;
        status.icon_theme = "material";
        whisper.model = "medium.en";
      };
    };

    # Workaround for voxtype user-service PATH issue (see upstream issue #253).
    systemd.user.services.voxtype = lib.mkIf config.programs.voxtype.service.enable {
      Service.Environment = [ "PATH=/run/current-system/sw/bin" ];
    };

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
      package = inputs.llm-agents.packages.${system}.opencode;
    };

    programs.claude-code = {
      enable = true;
      package = inputs.llm-agents.packages.${system}.claude-code;
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
