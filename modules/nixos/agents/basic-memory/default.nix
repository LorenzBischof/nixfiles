# Basic Memory for the agent wrappers: the plugin with its MCP server, hooks
# and skills (./plugin.nix), the CLI, the settings block both harnesses read,
# and the memory-reflect run that home-manager schedules per user.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  agents = config.my.programs.agents;
  cfg = agents.basicMemory;

  basicMemory = pkgs.callPackage ./plugin.nix {
    basicMemory = pkgs.callPackage ../../../../packages/basic-memory { inherit inputs; };
    inherit (cfg) notesDir stateDir;
  };

  # Hooks and skills read the `basicMemory` block of ~/.claude/settings.json
  # and ~/.codex/basic-memory.json. Per key, so a host can change one value
  # for one harness and keep the rest.
  hookSettings = lib.mapAttrs (_: lib.mkDefault) {
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
  inherit (agents.claude.settings.basicMemory) primaryProject;

  # Nobody watches this run and it reads text it did not write, so unlike the
  # bwrap wrappers it gets no blanket permissions: dontAsk denies everything but
  # the skill and the graph tools (no bm_delete, no shell, no web). bm_project is
  # left out because it can create projects, so the prompt points at bm_search.
  # Without --no-session-persistence each run would show up in work-log.
  memoryReflect = pkgs.writeShellApplication {
    name = "memory-reflect";
    # Spawned by systemd, so it cannot rely on session variables.
    runtimeEnv = {
      # Otherwise the run can start before the graph tools have connected, give
      # up and still exit 0.
      MCP_CONNECTION_NONBLOCKING = "false";
    };
    text = ''
      ${lib.getExe agents.wrappers.claude} -p ${lib.escapeShellArg ''
        Run the memory-reflect skill on project ${primaryProject}. Nobody is watching this run.
        bm_project is not available, so find changed notes with
        bm_search(since=<date of the last reflection>, project="${primaryProject}", page_size=50),
        paging until there are no more. Also check the active tasks and open
        decisions, and correct any that other notes show are out of date.
      ''} \
        --no-session-persistence \
        --model opus \
        --permission-mode dontAsk \
        --tools Skill \
        --allowedTools ${
          lib.escapeShellArgs (
            [ "Skill(basic-memory:memory-reflect)" ]
            ++ map (tool: "mcp__plugin_basic-memory_basic-memory__bm_${tool}") [
              "context"
              "edit"
              "find"
              "list"
              "read"
              "search"
              "write"
            ]
          )
        }
    '';
  };

  # Skips memory-reflect when the 5h or weekly window has less than 10% left
  # (exit 1 is a skip, not a failure) and retries once that window resets. If
  # the usage can't be read, the run goes ahead. Each check replaces any pending
  # retry, so a run that happens first makes the retry redundant.
  memoryReflectUsageCheck = pkgs.writeShellApplication {
    name = "memory-reflect-usage-check";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      systemd
    ];
    text = ''
      systemctl --user stop memory-reflect-retry.timer 2>/dev/null || true
      token="$(jq -r .claudeAiOauth.accessToken ~/.claude/.credentials.json)" || exit 0
      usage="$(curl -fsS https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $token" -H 'anthropic-beta: oauth-2025-04-20')" || exit 0
      reset="$(jq -r '[.five_hour, .seven_day | select(.utilization > 90) | .resets_at] | max // empty' <<<"$usage")"
      [ -z "$reset" ] && exit 0
      echo "Less than 10% usage left, retrying after $reset"
      systemd-run --user --unit=memory-reflect-retry --on-calendar="$(date -d "$reset 1 minute" '+%F %T')" \
        systemctl --user start memory-reflect.service
      exit 1
    '';
  };
in
{
  options.my.programs.agents.basicMemory = {
    enable = lib.mkEnableOption "the Basic Memory plugin, MCP server and CLI";
    notesDir = lib.mkOption {
      type = lib.types.str;
      default = "basic-memory";
      description = "Where each user's notes live, relative to their home.";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = ".basic-memory";
      description = "Where each user's SQLite index and config live, relative to their home.";
    };
    reflectPackage = lib.mkOption {
      readOnly = true;
      internal = true;
      default = pkgs.symlinkJoin {
        name = "memory-reflect";
        paths = [
          memoryReflect
          memoryReflectUsageCheck
        ];
      };
      description = ''
        The unattended memory-reflect run and its usage check. Scheduled from
        home-manager rather than here: it spends one user's quota on one
        user's graph, and NixOS user units install for every user.
      '';
    };
  };

  config = lib.mkIf (agents.enable && cfg.enable) {
    my.programs.agents = {
      plugins.basic-memory = basicMemory.plugin;
      claude.settings = {
        outputStyle = "basic-memory";
        basicMemory = hookSettings;
      };
      codex.ownedSettings."basic-memory.json".basicMemory = hookSettings;
      # Writes to the graph go through without a prompt each time.
      codex.config.plugins."basic-memory@nixos".mcp_servers.basic-memory.tools =
        lib.genAttrs
          [
            "write_note"
            "edit_note"
            "bm_write"
            "bm_edit"
          ]
          (_: {
            approval_mode = "approve";
          });
    };

    # For the parts of the graph the MCP tools do not cover: status, doctor,
    # project, reindex.
    environment.systemPackages = [ basicMemory.package ];
  };
}
