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
  baseCodex = pkgs.codex;
  baseClaude = inputs.llm-agents.packages.${system}.claude-code;
  signingPubKey =
    lib.replaceStrings [ "~" ] [ config.home.homeDirectory ]
      config.programs.jujutsu.settings.signing.key;
  signingKey = lib.removeSuffix ".pub" signingPubKey;
  codexNotify = pkgs.writeShellScriptBin "codex-notify" ''
    set -eu
    payload="''${1:-}"
    [ -n "$payload" ] || exit 0

    # Keep behavior stable if codex adds more events: only notify for agent-turn-complete.
    printf '%s' "$payload" | ${lib.getExe pkgs.jq} -e '.type == "agent-turn-complete"' >/dev/null 2>&1 || exit 0

    if [ -t 1 ]; then
      printf '\a' || true
    fi
  '';
  wrappedCodex =
    (pkgs.writeShellScriptBin "codex" ''
      exec ${lib.getExe baseCodex} ${lib.escapeShellArgs cfg.codexArgs} "$@"
    '').overrideAttrs
      {
        # Home Manager uses this to select config.toml instead of legacy YAML.
        inherit (baseCodex) version;
      };
  basicMemory = pkgs.callPackage ../../../packages/basic-memory { inherit inputs; };
  # The notes live in the syncthing folder shared with nas so they follow the
  # laptop; the SQLite index and config stay local, since the index rebuilds from
  # the markdown and syncing it would only produce conflicts.
  basicMemoryHome = "${config.home.homeDirectory}/files-lo/memory";
  basicMemoryStateDir = "${config.home.homeDirectory}/.basic-memory";
  basicMemoryEnv = {
    # Seeds the first project; subsequent projects live in config.json.
    BASIC_MEMORY_HOME = basicMemoryHome;
    # Declared rather than inherited: `resolve_data_dir` prefers this, then
    # $XDG_CONFIG_HOME/basic-memory, then ~/.basic-memory. Nothing sets
    # XDG_CONFIG_HOME today, but `xdg.enable` would, and that middle branch
    # points at an empty state dir — notes untouched, but every project needing
    # a re-add and reindex before a tool can see it.
    BASIC_MEMORY_CONFIG_DIR = basicMemoryStateDir;
    # Pin telemetry off even if upstream changes its defaults.
    BASIC_MEMORY_LOGFIRE_ENABLED = "false";
    BASIC_MEMORY_LOGFIRE_SEND_TO_LOGFIRE = "false";
    # The version comes from the flake input; a PyPI update check could only
    # ever nag, never apply.
    BASIC_MEMORY_AUTO_UPDATE = "false";
    # Rerank search hits with a local cross-encoder (jina-reranker-v1-tiny-en,
    # fetched once into the fastembed cache in the state dir): it puts the right
    # note first where embedding distance alone picks a schema or a tangent.
    BASIC_MEMORY_RERANKER_ENABLED = "true";
  };
  basicMemoryMcpServer = {
    command = lib.getExe basicMemory;
    args = [ "mcp" ];
    # Both harnesses spawn this themselves, so the graph it opens must not
    # depend on home.sessionVariables having been sourced.
    env = basicMemoryEnv;
  };
  # Both harnesses render this into every session brief, so it earns its place in
  # context by answering one question: which folder does a new note go in. What a
  # note of a given type holds lives in the schema notes in the graph instead.
  basicMemorySettings = {
    primaryProject = "main";
    # Claude Code's upstream default; pinned so Codex uses it too rather than
    # its own codex-remember/, which would split quick captures by harness.
    rememberFolder = "bm-remember";
    placementConventions =
      "Folders say what kind of note it is: notes/ for findings and research, "
      + "decisions/ for type: decision notes, tasks/ for work in flight, "
      + "people/ one per human, meetings/ one per meeting, clients/ one per "
      + "engagement, repositories/ one per git repo, schemas/ for schemas, "
      + "sessions/ for checkpoints, bm-remember/ for quick captures. "
      + "Link a repo as [[name]] instead of writing \"the repo\".";
  };
  # Upstream's hooks.json runs a Python launcher per hook through
  # `uv run --script`, resolving basic-memory and fastmcp from PyPI at every
  # session start. Each launcher only turns its own filename into
  # `basic-memory hook <verb>`, so this runner does that from the packaged CLI
  # and takes the launcher's path as its one argument — which means it stands in
  # for every hook the plugin ships, present and future.
  mkBasicMemoryHookRunner =
    harness:
    pkgs.writeShellApplication {
      name = "basic-memory-hook-${harness}";
      runtimeInputs = [ basicMemory ];
      # Spawned by the harness, not by a login shell, so it cannot rely on
      # home.sessionVariables below having been sourced.
      runtimeEnv = basicMemoryEnv;
      # No --project-dir, which upstream's Claude launcher passes from
      # CLAUDE_PROJECT_DIR: it only overrides the cwd the harness already sends
      # in the payload, and either way settings resolution walks up to the
      # nearest `.claude/settings*.json`. Worth re-adding only for a harness
      # that reports a cwd outside the project root.
      #
      # A failure inside a verb already exits 0 through the CLI's own fail-open
      # path, so what reaches here is a packaging bug worth seeing rather than
      # swallowing. Not passed through verbatim: typer exits 2 on a usage error,
      # and 2 is the one code PreCompact treats as blocking.
      text = ''
        # The launcher path is the only argument and its name is the verb:
        # ".../hooks/pre_compact.py" -> `basic-memory hook pre-compact`.
        verb=$(basename "''${1:-}" .py)
        basic-memory hook "''${verb//_/-}" --harness ${harness} || exit 1
      '';
    };
  # The plugins come from the package source — they carry the bm-* skills, the
  # output style and Codex's manifest — with the uv launch prefix in hooks.json
  # swapped for the runner. `--replace-fail` so a release that stops shipping
  # that prefix fails the build instead of quietly reaching for uv.
  mkBasicMemoryPlugin =
    {
      pluginDir,
      harness,
      extraSetup ? "",
    }:
    pkgs.runCommand pluginDir { inherit (basicMemory) version; } ''
      cp -r ${basicMemory.src}/plugins/${pluginDir} $out
      chmod -R u+w $out
      substituteInPlace $out/hooks/hooks.json \
        --replace-fail 'uv run --quiet --script' ${lib.getExe (mkBasicMemoryHookRunner harness)}
      ${extraSetup}
    '';
  basicMemoryCodexPlugin = mkBasicMemoryPlugin {
    pluginDir = "codex";
    harness = "codex";
    # Upstream's own .mcp.json launches the server with `uvx basic-memory`.
    extraSetup = ''
      cp ${
        (pkgs.formats.json { }).generate "basic-memory-mcp.json" {
          mcpServers.basic-memory = basicMemoryMcpServer // {
            required = true;
          };
        }
      } $out/.mcp.json
    '';
  };
  basicMemoryClaudePlugin = mkBasicMemoryPlugin {
    pluginDir = "claude-code";
    harness = "claude";
  };
  # Our own skills plus the shared memory-* ones, merged into a single directory
  # so Claude Code and Codex are handed the same set. Upstream keeps these
  # outside the Claude Code plugin deliberately and expects `npx skills add` to
  # fetch them into ~/.claude/skills; linking them out of the pinned source
  # instead keeps them in lockstep with the MCP server, off the network, and out
  # of a directory home-manager owns. The glob takes whatever upstream ships, so
  # a version bump adds or drops skills on its own.
  aiSkills = pkgs.runCommand "ai-skills" { } ''
    mkdir -p $out
    ln -s ${./skills}/* $out/
    ln -s ${basicMemory.src}/skills/memory-* $out/
  '';
  workLogExtract = pkgs.writers.writePython3Bin "work-log-extract" {
    flakeIgnore = [
      "E501" # long lines read fine; wrapping them hurts more than it helps here
      "W503" # black-style line breaks before binary operators
    ];
  } (builtins.readFile ./skills/work-log/extract.py);
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

        # basic-memory's MCP server writes the knowledge graph and its SQLite
        # index. The sandbox home is a tmpdir wiped on exit, so without these
        # binds every note the agent writes is lost silently.
        bind_existing "${basicMemoryHome}"
        bind_existing "${basicMemoryStateDir}"

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
          bwrap_args+=(--bind /run/opengl-driver /run/opengl-driver)
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
    extraArgs = [ "--dangerously-bypass-approvals-and-sandbox" ];
  };
  claudeBwrap = mkBwrapTool {
    name = "claude-bwrap";
    executable = lib.getExe baseClaude;
    configDirName = ".claude";
    extraArgs = [
      "--dangerously-skip-permissions"
      "--settings"
      (builtins.toJSON { sandbox.enabled = false; })
    ];
  };
  piBwrap = mkBwrapTool {
    name = "pi-bwrap";
    executable = lib.getExe inputs.llm-agents.packages.${system}.pi;
    configDirName = ".pi";
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
        "on-request"
        "-c"
        "sandbox_workspace_write.network_access=true"
      ];
    };
    agentsFile = lib.mkOption {
      type = lib.types.path;
      default = ./AGENTS.md;
      description = "Source AGENTS.md file for AI tools.";
    };
  };
  config = lib.mkIf cfg.enable {
    # `basic-memory`/`bm` on PATH has no call site to hang an env on, so the
    # environment goes into the session instead: `bm status`, `bm doctor` and
    # `bm tool ...` then read the same state dir as the MCP server.
    home.sessionVariables = basicMemoryEnv;

    home.packages = [
      pkgs.nil
      # On PATH for the CLI side of the knowledge graph (status, doctor, project,
      # reindex), which the MCP tools do not cover.
      basicMemory
      pkgs.obsidian
      # Agents reach for python3 for one-off scripting; without it on PATH they
      # fall back to awk and sed, which is where the fiddly mistakes come from.
      pkgs.python3
      pkgs.socat
      codexBwrap
      claudeBwrap
      piBwrap
      workLogExtract
      inputs.llm-agents.packages.${system}.pi
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

    # Created ahead of first use so the bubblewrap wrappers have something to
    # bind: basic-memory creates them lazily otherwise, and inside a sandbox
    # that means creating them in a tmpdir that is wiped on exit.
    home.activation.basicMemoryDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p ${lib.escapeShellArg basicMemoryHome} ${lib.escapeShellArg basicMemoryStateDir}
    '';

    programs.voxtype = {
      enable = true;
      # Use the upstream ONNX package for Parakeet transcription on the CPU.
      package = inputs.voxtype.packages.${system}.onnx;
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
      # Workaround for voxtype user-service PATH issue (see upstream issue #253).
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
      package = inputs.llm-agents.packages.${system}.opencode;
    };

    programs.claude-code = {
      enable = true;
      package = inputs.llm-agents.packages.${system}.claude-code;
      # No "Co-Authored-By: Claude" on commits and no "Generated with Claude
      # Code" on pull requests. Commits here are the description line and nothing
      # else.
      settings = {
        includeCoAuthoredBy = false;
        # The hooks read this before any project-level block, so one declaration
        # covers every repository; a repo that wants a different graph or
        # placement overrides it in its own .claude/settings.local.json.
        basicMemory = basicMemorySettings;
        outputStyle = "basic-memory";
        spinnerVerbs = {
          mode = "replace";
          verbs = [ "Working" ];
        };
        spinnerTipsEnabled = false;
        prefersReducedMotion = true;
        feedbackSurveyRate = 0;
        # The default "auto" only knows iTerm2, kitty, Ghostty and Apple
        # Terminal; in foot it resolves to no channel at all.
        preferredNotifChannel = "terminal_bell";
      };
      # Required, because the rest of ~/.claude/settings.json is hand-maintained:
      # the default merges nothing and would replace that file with a read-only
      # store symlink holding only what is declared here. With this, activation
      # merges the declared keys into the writable file and leaves the others
      # alone - at the price that removing a declaration later does not remove it
      # from the file.
      mutableSettings = true;
      # Declared through the module rather than as a `home.file` directory
      # symlink: the module installs this one recursively, which leaves
      # ~/.claude/skills a real directory. The MCP server above is delivered as
      # a generated plugin that the module places at
      # .claude/skills/claude-code-home-manager, and it cannot write a sibling
      # into a path that is itself a single store symlink.
      skills = aiSkills;
      # The MCP server below exposes the tools; this plugin wires the graph into
      # the session — a SessionStart hook that briefs from active tasks and open
      # decisions, a PreCompact hook that checkpoints before compaction, plus the
      # bm-* skills and an output style.
      plugins.basic-memory = basicMemoryClaudePlugin;
      # Registered for every project, not just this repo: home-manager writes it
      # into a generated user-level plugin, so the tools arrive as
      # mcp__plugin_hm_basic-memory__*.
      mcpServers.basic-memory = basicMemoryMcpServer;
    };

    programs.codex = {
      enable = true;
      package = wrappedCodex;
      # Preserve Codex's user-managed configuration when enabling the plugin.
      mutableSettings = true;
      settings = {
        notify = [ (lib.getExe codexNotify) ];
        tui.animations = false;
      };
      plugins = [ basicMemoryCodexPlugin ];
    };

    home.file = {
      ".agents/skills".source = aiSkills;

      # Global Claude Code context file
      ".claude/CLAUDE.md".text = renderedAgentsMd;

      # Global Codex context file
      ".codex/AGENTS.md".text = renderedAgentsMd;

      # Pin the existing graph and the placement conventions; let upstream
      # supply the rest of the workflow defaults.
      ".codex/basic-memory.json".text = builtins.toJSON {
        basicMemory = basicMemorySettings;
      };

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
