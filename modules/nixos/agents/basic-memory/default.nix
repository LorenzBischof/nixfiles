# Basic Memory for the agent wrappers: the plugin with its MCP server, hooks
# and skills (./plugin.nix), the CLI, the settings block both harnesses read,
# and the twice-weekly memory-reflect run for one user.
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
  llmAgents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

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

  # The hc template the run starts: hc types its body and the task in as the
  # first message. The run reads no CLAUDE.md, so not the home folder's
  # instructions every other session there gets; the variable goes on the
  # command because the terminal gets the hc core's environment, not the unit's.
  reflectTemplate = pkgs.writeText "memory-reflect.md" ''
    ---
    name: memory-reflect
    description: Consolidate the Basic Memory graph
    command: CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude --model opus
    ---

    Run the memory-reflect skill on project ${primaryProject}. Also check the
    active tasks and open decisions, and correct any that other notes show are
    out of date.
  '';

  # An interactive Claude in an hc terminal, like a session started by hand: it
  # shows up as a tab of the "memory-reflect" space in Herdr and ovis, where it
  # can be watched, steered, asked about afterwards or unblocked on a prompt.
  # The script waits until Claude reports its turn done, so the unit stays
  # active exactly as long as the run. The hc terminal and the tab id are the
  # date. The last three runs stay open; older ones are closed before a new one.
  #
  # Exits 75 (EX_TEMPFAIL) without running when the 5h or weekly window of
  # the account the run would get (claude-account's first) has less than 10%
  # left, which the unit below retries hourly. Only this scheduled run waits;
  # a session started by hand or by an agent always gets an account. If the
  # usage can't be read, the run goes ahead.
  #
  # It starts in an empty folder of its own, not the notes folder, where a note
  # named CLAUDE.md would become instructions; Herdr names the space after it.
  # That folder has to be trusted for Claude once on each account (start
  # `CLAUDE_CONFIG_DIR=~/.claude-NAME claude` there and accept): hc doesn't
  # type the task in while the trust dialog shows, and trust is kept in each
  # account's own .claude.json.
  reflectDir = "~/.local/state/memory-reflect";
  memoryReflect = pkgs.writeShellApplication {
    name = "memory-reflect";
    runtimeInputs = [
      pkgs.jq
      llmAgents.herdr-core
    ];
    text = ''
      if usage="$(${lib.getExe agents.wrappers.claude-account} usage)"; then
        reset="$(jq -r '.[0].usage | [.five_hour, .seven_day | select(.utilization > 90) | .resets_at] | max // empty' <<<"$usage")"
        if [ -n "$reset" ]; then
          echo "Less than 10% usage left until $reset"
          exit 75
        fi
      fi

      today="$(date +%F)"
      # Names are dates, so sorting them sorts the runs.
      hc ls --all --json --label herdr.space=memory-reflect |
        jq -r '.terminals[] | "\(.name) \(.address)"' | sort | head -n -2 |
        while read -r _ address; do
          hc kill "$address" >/dev/null 2>&1 || true
          hc wait "$address" --timeout 10 >/dev/null 2>&1 || true
          hc rm "$address" >/dev/null
        done

      # A run already going today (started by hand, or this unit restarted by a
      # deploy) is waited on rather than started again.
      if [ "$(hc get "$today" 2>/dev/null | jq -r .state)" != live ]; then
        mkdir -p ${reflectDir} ~/.config/herdr-core/templates
        ln -sf ${reflectTemplate} ~/.config/herdr-core/templates/memory-reflect.md
        started="$(hc run --bg --json --name "$today" --cwd ${reflectDir} \
          --label herdr.space=memory-reflect --label herdr.tab="$today" \
          memory-reflect "The reflection of $today.")"
        if [ "$(jq -r .first_message.sent <<<"$started")" != true ]; then
          echo "The task was not sent: $(jq -r .first_message.reason <<<"$started")"
          exit 1
        fi
        echo "Started $(jq -r .address <<<"$started")"
      fi

      # hc wait returns on every status change and every 180 s, but at once
      # while Claude is blocked or idle, hence the sleep.
      while sleep 10; do
        result="$(hc wait "$today" --json | jq -r 'if .reason == "exit" then "exit" else .status // "" end')"
        case "$result" in
          done) exit 0 ;;
          error) echo "Claude reported an error"; exit 1 ;;
          exit) echo "Claude exited before finishing"; exit 1 ;;
        esac
      done
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
    reflect.user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The user whose graph memory-reflect consolidates twice a week, spending
        that user's Claude quota; null for no scheduled reflection.
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

    # A system unit running as that user: User= sets HOME, so Claude finds the
    # user's credentials and graph, and hc that user's core. Exit 75 (too
    # little quota) is retried hourly until the window resets; any other
    # failure is not, so a broken run cannot spend quota in a loop. No start
    # timeout: a run may wait on a prompt until someone answers it. Stopping
    # the unit doesn't end Claude, which runs in hc's own unit (close its tab),
    # and a restart goes back to waiting on it.
    systemd.services.memory-reflect = lib.mkIf (cfg.reflect.user != null) {
      description = "Consolidate the Basic Memory graph";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.reflect.user;
        ExecStart = lib.getExe memoryReflect;
        TimeoutStartSec = "infinity";
        RestartForceExitStatus = 75;
        RestartSec = "1h";
      };
    };

    systemd.timers.memory-reflect = lib.mkIf (cfg.reflect.user != null) {
      description = "Twice-weekly Basic Memory reflection";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon,Thu 12:30";
        Persistent = true;
      };
    };
  };
}
