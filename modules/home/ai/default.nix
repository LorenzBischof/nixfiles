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
  codexNotifyConfigArg = "notify=[\"${lib.getExe codexNotify}\"]";
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

        # nix-ld loader; NIX_LD/NIX_LD_LIBRARY_PATH are session vars and pass through already.
        ro_bind_existing "/lib64"

        ro_bind_existing "$HOME/.nix-profile"
        ro_bind_existing "$HOME/.local/state/nix/profiles"

        ro_bind_existing "$HOME/.config/jj/config.toml"

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
    extraArgs = [
      "--dangerously-skip-permissions"
      "--settings"
      (builtins.toJSON {
        sandbox.enabled = false;
        spinnerVerbs = {
          mode = "replace";
          verbs = [ "Working" ];
        };
        spinnerTipsEnabled = false;
        prefersReducedMotion = true;
        feedbackSurveyRate = 0;
        preferredNotifChannel = "terminal_bell";
      })
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
  };
  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.nil
      pkgs.socat
      codexBwrap
      claudeBwrap
      piBwrap
      inputs.llm-agents.packages.${system}.pi
      #inputs.nix-ai-tools.packages.${system}.openclaw
    ];

    programs.voxtype = {
      enable = true;
      # nixpkgs' voxtype builds the ONNX engines without `cohere`, so take the
      # package from the flake input instead. Still the CPU build: the NPU is
      # unreachable either way (voxtype's `setup npu` gates on Intel's
      # intel_vpu driver and routes to OpenVINO, and no ONNX execution
      # provider here targets AMD's XDNA), and the 860M would need
      # `onnx-migraphx`, which is untested against this model.
      # Keep Parakeet's final flush on record stop (upstream issue #804).
      package = inputs.voxtype.packages.${system}.onnx.overrideAttrs {
        paths = [
          (inputs.voxtype.packages.${system}.voxtype-onnx-unwrapped.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./voxtype-parakeet-drain.patch ];
          }))
        ];
      };
      service.enable = true;
      settings = {
        hotkey.enabled = false;
        status.icon_theme = "material";
        # Set via `settings` rather than `programs.voxtype.engine`: the
        # module's enum still predates the cohere engine.
        engine = "parakeet";
        parakeet = {
          # Streaming needs a cache-aware model, and this is the only one in
          # voxtype's registry that qualifies — every int8 Parakeet variant is
          # flagged streaming_compatible = false, so this runs fp32 weights
          # (2.6 GB) where cohere ran q4f16 (1.5 GB). English only. Fetched
          # imperatively into ~/.local/share/voxtype/models with
          # `voxtype setup model parakeet-unified-en-0.6b`.
          model = "parakeet-unified-en-0.6b";
          # Types partial deltas at the cursor while you speak instead of
          # committing the whole utterance on key release. A transducer, so
          # each 0.5s chunk costs the same no matter how long you talk; the
          # tradeoff is that inference runs for the whole hold, pauses
          # included. The schema calls this "forces toggle activation", but
          # that only binds voxtype's own hotkey grabber, which is off here —
          # the press/release ssharp binding in modules/home/wayland still
          # drives it through `voxtype record start` / `stop`.
          streaming = true;
          # parakeet-rs rejects any window that isn't a whole number of
          # 8-mel-frame blocks, and at a 10 ms hop that means every one of
          # these has to be a multiple of 0.08s. All three upstream defaults
          # (0.5 / 1.5 / 0.5 -> 50 / 150 / 50 frames) fail that check, so
          # `streaming = true` cannot start without overriding them here.
          # Rounded down to the nearest valid step to keep latency at or under
          # what the defaults asked for.
          streaming_chunk_secs = 0.48;
          streaming_left_context_secs = 1.52;
          streaming_right_context_secs = 0.48;
        };
        # Kept for a one-line revert: encoder-decoder, no 30s mel padding, and
        # 14 languages against Parakeet's English, but batch-only — nothing
        # wraps it in the sliding-window streaming transcriber upstream.
        cohere.model = "cohere-transcribe-q4f16";
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
    };

    programs.codex = {
      enable = true;
      package = wrappedCodex;
    };

    home.file = {
      ".agents/skills".source = ./skills;
      ".claude/skills".source = ./skills;

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
