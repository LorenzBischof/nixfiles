{
  config,
  osConfig,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  cfg = config.my.profiles.ai;
  system = pkgs.stdenv.hostPlatform.system;
  agents = osConfig.my.programs.agents;
  signingPubKey =
    lib.replaceStrings [ "~" ] [ config.home.homeDirectory ]
      config.programs.jujutsu.settings.signing.key;
  signingKey = lib.removeSuffix ".pub" signingPubKey;
  # The bwrap wrappers bind these so the graph outlives the sandbox's tmp home.
  basicMemoryHome = "${config.home.homeDirectory}/${agents.basicMemory.notesDir}";
  basicMemoryStateDir = "${config.home.homeDirectory}/${agents.basicMemory.stateDir}";
  # Inside bwrap the bubblewrap jail replaces Claude's own sandbox. A second
  # --settings flag would replace the wrapper's rather than merge with it.
  sandboxedWrappers = agents.wrappers.override (old: {
    claudeFlagSettings = lib.recursiveUpdate old.claudeFlagSettings {
      sandbox.enabled = false;
    };
  });
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
          ca_bundle="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          ca_cert_dir="${pkgs.cacert}/etc/ssl/certs"
          nix_daemon_socket_dir="/nix/var/nix/daemon-socket"

          cleanup() {
            rm -rf "$sandbox_root"
          }
          trap cleanup EXIT

          mkdir -p "$sandbox_home"


          declare -a bwrap_args=(
            --die-with-parent
            --unshare-all
            --share-net
            --proc /proc
            --dev /dev
            --tmpfs /tmp
            --tmpfs /run
            --dir /run/user/1000
            --dir /bin
            --dir /usr
            --dir /usr/bin
            --dir /etc
            --dir /home
            --ro-bind /bin/sh /bin/sh
            --ro-bind /usr/bin/env /usr/bin/env
            --ro-bind /nix/store /nix/store
            --ro-bind /run/current-system/sw /run/current-system/sw
            --ro-bind /etc/static /etc/static
            --ro-bind /etc/profiles /etc/profiles
            --ro-bind /etc/resolv.conf /etc/resolv.conf
            --ro-bind /etc/hosts /etc/hosts
            --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf
            --ro-bind /etc/passwd /etc/passwd
            --ro-bind /etc/group /etc/group
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

          ro_bind_existing() {
            if [ -e "$1" ]; then
              bwrap_args+=(--ro-bind "$1" "$1")
            fi
          }

          bind_existing() {
            if [ -e "$1" ]; then
              bwrap_args+=(--bind "$1" "$1")
            fi
          }

          # nix-ld loader; NIX_LD/NIX_LD_LIBRARY_PATH are session vars and pass through already.
          ro_bind_existing "/lib64"

          ro_bind_existing "$HOME/.nix-profile"
          ro_bind_existing "$HOME/.local/state/nix/profiles"

          ro_bind_existing "$HOME/.config/jj/config.toml"

          # The repo is writable, but git config (core.fsmonitor, core.hooksPath,
          # aliases) and hooks would run in the next unsandboxed git call.
          if [ -d "$repo_root/.git" ]; then
            mkdir -p "$repo_root/.git/hooks"
            ro_bind_existing "$repo_root/.git/config"
            ro_bind_existing "$repo_root/.git/config.worktree"
            ro_bind_existing "$repo_root/.git/hooks"
          fi

        ${lib.optionalString agents.basicMemory.enable ''
          # basic-memory's MCP server writes the knowledge graph and its SQLite
          # index. The sandbox home is a tmpdir wiped on exit, so without these
          # binds every note the agent writes is lost silently. Created first, as
          # basic-memory would otherwise create them lazily inside that tmpdir.
          mkdir -p "${basicMemoryHome}" "${basicMemoryStateDir}"
          bwrap_args+=(--bind "${basicMemoryHome}" "${basicMemoryHome}")
          bwrap_args+=(--bind "${basicMemoryStateDir}" "${basicMemoryStateDir}")
        ''}

          # Allow sandboxed tools to use the host Nix daemon without exposing the DB.
          if [ -S "$nix_daemon_socket_dir/socket" ]; then
            bwrap_args+=(--bind "$nix_daemon_socket_dir" "$nix_daemon_socket_dir")
          fi

          if [ -d "$config_source" ]; then
            bwrap_args+=(--bind "$config_source" "$HOME/${configDirName}")
          fi

          if [ -d "$HOME/.agents" ]; then
            bwrap_args+=(--bind "$HOME/.agents" "$HOME/.agents")
          fi

          if [ -r "${signingKey}" ]; then
            bwrap_args+=(
              --ro-bind "${signingKey}" "${signingKey}"
              --ro-bind "${signingPubKey}" "${signingPubKey}"
            )
          fi

          if [ -f "$HOME/${configDirName}.json" ]; then
            bwrap_args+=(--bind "$HOME/${configDirName}.json" "$HOME/${configDirName}.json")
          fi

          nix_config="experimental-features = nix-command flakes"

          github_token_file="/run/agenix/github-token"
          if [ -r "$github_token_file" ]; then
            nix_config="$nix_config
            $(cat "$github_token_file")"
            github_token="$(grep -oP '(?<=github\.com=)\S+' "$github_token_file" || true)"
            bwrap_args+=(
              --setenv GH_TOKEN "$github_token"
              --setenv GITHUB_TOKEN "$github_token"
            )
          fi

          bwrap_args+=(--setenv NIX_CONFIG "$nix_config")

          # Allow the AI wrappers to launch local test VMs from inside bubblewrap.
          if [ -e /dev/kvm ]; then
            bwrap_args+=(--dev-bind /dev/kvm /dev/kvm)
          fi

          if [ -d /dev/dri ]; then
            bwrap_args+=(--dev-bind /dev/dri /dev/dri)
          fi

          if [ -d /run/opengl-driver ]; then
            bwrap_args+=(--ro-bind /run/opengl-driver /run/opengl-driver)
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
    executable = lib.getExe sandboxedWrappers.codex;
    configDirName = ".codex";
    extraArgs = [ "--dangerously-bypass-approvals-and-sandbox" ];
  };
  claudeBwrap = mkBwrapTool {
    name = "claude-bwrap";
    executable = lib.getExe sandboxedWrappers.claude;
    configDirName = ".claude";
    extraArgs = [ "--dangerously-skip-permissions" ];
  };
  piBwrap = mkBwrapTool {
    name = "pi-bwrap";
    executable = lib.getExe pkgs.llm-agents.pi;
    configDirName = ".pi";
  };
  renderedAgentsMd = builtins.readFile cfg.agentsFile;
in
{
  imports = [
    inputs.voxtype.homeManagerModules.default
  ];
  options.my.profiles.ai = {
    enable = lib.mkEnableOption "ai";
    agentsFile = lib.mkOption {
      type = lib.types.path;
      default = ./AGENTS.md;
      description = "Source AGENTS.md file for AI tools.";
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.nil
      pkgs.obsidian
      # Also used by browser automation.
      pkgs.nodejs
      pkgs.socat
      codexBwrap
      claudeBwrap
      piBwrap
      pkgs.llm-agents.pi
      #inputs.nix-ai-tools.packages.${system}.openclaw
    ];

    # Ring the idle bell after 10s instead of 60s. Undocumented: Claude Code
    # reads this key only from ~/.claude.json, its own state file, so it is
    # merged in rather than declared in settings.json.
    home.activation.claudeIdleNotifThreshold = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      claude_json="$HOME/.claude.json"
      if [ -f "$claude_json" ] && [ -z "''${DRY_RUN:-}" ]; then
        tmp="$(mktemp "$claude_json.XXXXXX")"
        ${lib.getExe pkgs.jq} '.messageIdleNotifThresholdMs = 10000' "$claude_json" > "$tmp"
        mv "$tmp" "$claude_json"
      fi
    '';

    programs.voxtype = {
      enable = true;
      # Use the upstream ONNX package for Parakeet transcription on the CPU.
      # TODO: nixpkgs' cargoSetupHook forces onig_sys and libsqlite3-sys onto
      # system libraries since #537108, and the voxtype flake doesn't provide
      # them (nixpkgs' own voxtype got both in #585434). No upstream issue or
      # fix, still missing on voxtype main as of 2026-11. Drop the override
      # once the flake's onnx build lists oniguruma and sqlite.
      package = inputs.voxtype.packages.${system}.onnx.overrideAttrs {
        paths = [
          (inputs.voxtype.packages.${system}.voxtype-onnx-unwrapped.overrideAttrs (old: {
            buildInputs = old.buildInputs ++ [
              pkgs.oniguruma
              pkgs.sqlite
            ];
          }))
        ];
      };
      service.enable = true;
      settings = {
        hotkey.enabled = false;
        status.icon_theme = "material";
        engine = "parakeet";
        # A TDT transducer, punctuated, 25 European languages,
        # fp32 weights (2.6 GB). Also batch-only — this is the v3 the registry
        # recommends, not the `parakeet-unified-en-0.6b` that the streaming
        # pipeline needs, which is English-only and was tried and dropped. No
        # thread knob exists; parakeet-rs sizes its own ONNX session. Fetched
        # with `voxtype setup --download --model parakeet-tdt-0.6b-v3`.
        parakeet.model = "parakeet-tdt-0.6b-v3";
        # The floating waveform panel duplicates what the quickshell bar
        # already draws (the level strip and the state icon in
        # modules/home/wayland/quickshell), and it cannot render anyway: this
        # package ships no `voxtype-osd-gtk4`, so the daemon falls back to
        # `voxtype-osd-quickshell`, which wants QML that only
        # `voxtype setup quickshell` installs imperatively. Left on, that is
        # three failed child spawns and an ERROR line on every start.
        osd.enabled = false;
        # The text is already at the cursor by the time this fires, so the
        # notification only repeats it over whatever is being dictated into.
        # The other two are off upstream; this one defaults on.
        output.notification.on_transcription = false;
      };
    };

    systemd.user.services.voxtype = lib.mkIf config.programs.voxtype.service.enable {
      # TODO: The voxtype flake's wrapper only puts its typing/clipboard tools on
      # PATH, not `which`, which the daemon shells out to. voxtype#253 was closed
      # by fixing the nixpkgs package (NixOS/nixpkgs#520520), not this flake's,
      # and no upstream issue is open for the flake as of 2026-11. Drop this once
      # the flake's runtimeDeps include `which`.
      Service.Environment = [ "PATH=/run/current-system/sw/bin" ];
      # The daemon reads config.toml once at startup and never re-reads it,
      # and upstream's unit doesn't name the file — so a settings-only change
      # leaves the unit text byte-identical, sd-switch leaves the running
      # daemon alone, and the old settings stay live until the next logout.
      # Naming the file here makes every settings change a unit change, so
      # `just switch` restarts the daemon.
      Unit.X-Restart-Triggers = [
        "${config.xdg.configFile."voxtype/config.toml".source}"
      ];
    };

    programs.opencode = {
      enable = true;
      package = pkgs.llm-agents.opencode;
    };

    home.file = {
      # Global Claude Code context file
      ".claude/CLAUDE.md".text = renderedAgentsMd;

      # Global Codex context file
      ".codex/AGENTS.md".text = renderedAgentsMd;

      # Global Pi context file
      ".pi/agent/AGENTS.md".text = renderedAgentsMd;

      ".pi/agent/models.json".text = builtins.toJSON {
        providers = {
          llama-cpp = {
            baseUrl = "http://127.0.0.1:8080/v1";
            api = "openai-completions";
            apiKey = "none";
            compat = {
              supportsDeveloperRole = false;
              supportsReasoningEffort = false;
            };
            models = [
              {
                id = "qwen3.6";
                input = [
                  "text"
                  "image"
                ];
              }
              {
                id = "qwen3-coder";
              }
              {
                id = "gemma4";
                input = [
                  "text"
                  "image"
                ];
              }
            ];
          };
          flm = {
            baseUrl = "http://127.0.0.1:52625/v1";
            api = "openai-completions";
            apiKey = "none";
            compat = {
              supportsDeveloperRole = false;
              supportsReasoningEffort = false;
            };
            # The server loads the requested model on demand.
            models = map (id: {
              inherit id;
              input = [
                "text"
                "image"
              ];
            }) (import ./flm-models.nix).models;
          };
        };
      };
    };
  };
}
