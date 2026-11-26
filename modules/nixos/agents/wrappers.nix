# Claude Code and Codex wrappers that pass the setup as launch flags where the
# CLIs take one, so what users add by hand keeps working. Settings that other
# readers need too (plugin hooks and skills read the files, never the flags)
# are merged into the user's files at launch instead, see ownedSettings below.
# Our skills ship as one more plugin, so both CLIs load everything the
# same way, at the price of a namespace (`nixos:grill-me`). The skills of the
# terminal app's orchestrator ship as a plugin of their own per app, and the
# wrapper loads only the one for the app it starts in. Instructions are left
# to ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md and the repositories.
{
  lib,
  runCommand,
  linkFarm,
  writeShellApplication,
  writeText,
  coreutils,
  util-linux,
  jq,
  claude-code,
  codex,
  # In nixpkgs' installAgentSkills layout; their bin/ goes on PATH.
  skillPackages,
  # { hc = [ … ]; orca = [ … ]; }: skill packages per orchestrator, in the same
  # layout. A launch in an Orca terminal gets orca's, any other launch hc's.
  orchestratorSkills,
  # Name -> a directory with both a .claude-plugin and a .codex-plugin manifest,
  # or { claude = dir; codex = dir; } where the two differ (null leaves one out).
  plugins,
  # In Claude's .mcp.json shape.
  mcpServers,
  # Top-level keys owned in $CLAUDE_CONFIG_DIR/settings.json.
  claudeSettings,
  # Passed as --settings, above every settings file. Only for what must differ
  # per wrapper while ~/.claude is shared, like the bwrap wrappers' sandbox.
  claudeFlagSettings,
  # Codex merges each top-level key into the user's table of that name (0.169).
  codexConfig,
  # File under $CODEX_HOME -> top-level keys owned in it.
  codexOwnedSettings,
}:
let
  name = "nixos";
  manifest = {
    inherit name;
    version = "0.0.0";
    description = "Skills from nixfiles";
  };

  mkSkillsPlugin =
    manifest: packages:
    runCommand "${manifest.name}-skills-plugin" { } ''
      mkdir -p $out/skills $out/.claude-plugin $out/.codex-plugin
      for pkg in ${lib.escapeShellArgs packages}; do
        cp -rL "$pkg"/share/skills/*/* $out/skills/
      done
      echo ${lib.escapeShellArg (builtins.toJSON manifest)} > $out/.claude-plugin/plugin.json
      echo ${
        lib.escapeShellArg (builtins.toJSON (manifest // { skills = "./skills/"; }))
      } > $out/.codex-plugin/plugin.json
    '';
  skillsPlugin = mkSkillsPlugin manifest skillPackages;
  orchestratorPlugins = lib.mapAttrs (
    orchestrator: mkSkillsPlugin (manifest // { name = orchestrator; })
  ) orchestratorSkills;

  allPlugins =
    lib.mapAttrs (
      _: dir:
      if dir ? claude && dir ? codex then
        dir
      else
        {
          claude = dir;
          codex = dir;
        }
    ) plugins
    // lib.mapAttrs (_: dir: {
      claude = dir;
      codex = dir;
    }) ({ ${name} = skillsPlugin; } // orchestratorPlugins);
  pluginsFor =
    harness: lib.filterAttrs (_: dir: dir != null) (lib.mapAttrs (_: dirs: dirs.${harness}) allPlugins);
  claudePlugins = pluginsFor "claude";
  codexPlugins = pluginsFor "codex";

  marketplace = linkFarm "${name}-marketplace" (
    lib.mapAttrs' (plugin: lib.nameValuePair "plugins/${plugin}") codexPlugins
    // {
      ".agents/plugins/marketplace.json" = builtins.toFile "marketplace.json" (
        builtins.toJSON {
          inherit name;
          interface.displayName = "NixOS";
          plugins = map (plugin: {
            name = plugin;
            source = {
              source = "local";
              path = "./plugins/${plugin}";
            };
            policy = {
              installation = "AVAILABLE";
              authentication = "ON_INSTALL";
            };
            category = "Productivity";
          }) (lib.attrNames codexPlugins);
        }
      );
    }
  );

  # Inline TOML for `-c`. Keys are quoted so `egm@nixos` stays one key; JSON
  # scalars and lists are valid TOML.
  toToml =
    value:
    if lib.isAttrs value then
      "{"
      + lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${builtins.toJSON k}=${toToml v}") value)
      + "}"
    else
      builtins.toJSON value;

  # The skills plugins of every orchestrator but this one.
  others = orchestrator: lib.remove orchestrator (lib.attrNames orchestratorPlugins);

  codexSettings =
    orchestrator:
    lib.recursiveUpdate {
      # Codex has no `type`; it tells the transport from `url` or `command`.
      mcp_servers = lib.mapAttrs (_: server: removeAttrs server [ "type" ]) mcpServers;
      features.plugins = true;
      marketplaces.${name} = {
        source_type = "local";
        source = "${marketplace}";
      };
      # The others are turned off rather than left out, so one a user enabled
      # in their own config.toml stays off too.
      plugins = lib.mapAttrs' (
        plugin: _:
        lib.nameValuePair "${plugin}@${name}" { enabled = !lib.elem plugin (others orchestrator); }
      ) codexPlugins;
    } codexConfig;

  codexArgs =
    orchestrator:
    lib.concatLists (
      lib.mapAttrsToList (key: value: [
        "-c"
        "${key}=${toToml value}"
      ]) (codexSettings orchestrator)
    );

  # --mcp-config takes several values; --settings after it ends the list, so a
  # prompt is not read as one.
  claudeArgs =
    orchestrator:
    [
      "--mcp-config"
      (builtins.toJSON { inherit mcpServers; })
      "--settings"
      (builtins.toJSON claudeFlagSettings)
    ]
    ++ lib.concatMap (dir: [
      "--plugin-dir"
      "${dir}"
    ]) (lib.attrValues (removeAttrs claudePlugins (others orchestrator)));

  pathPrefix = ''
    export PATH=${
      lib.makeBinPath (skillPackages ++ lib.concatLists (lib.attrValues orchestratorSkills))
    }:"$PATH"
  '';

  # Orca marks its terminals with ORCA_TERMINAL_HANDLE; everything else, hc's
  # terminals and plain shells alike, gets hc.
  execFor = command: args: ''
    if [ -n "''${ORCA_TERMINAL_HANDLE:-}" ]; then
      exec ${command} ${lib.escapeShellArgs (args "orca")} "$@"
    fi
    exec ${command} ${lib.escapeShellArgs (args "hc")} "$@"
  '';

  # Each owned key replaces the user's whole key of that name, and the rest of
  # the file is left alone. Parallel launches need no lock: they all write the
  # same values.
  ownedSettings =
    configDir: files:
    lib.optionalString (files != { }) ''
      merge_owned() {
        local target=$1 owned=$2 tmp
        mkdir -p "$(dirname "$target")"
        [ -e "$target" ] || echo '{}' >"$target"
        tmp=$(mktemp "$target.XXXXXX")
        jq --slurpfile o "$owned" '. + $o[0]' "$target" >"$tmp"
        mv -f "$tmp" "$target"
      }
      ${lib.concatStrings (
        lib.mapAttrsToList (file: keys: ''
          merge_owned ${configDir}/${lib.escapeShellArg file} ${writeText "owned.json" (builtins.toJSON keys)}
        '') files
      )}
    '';

in
{
  claude = writeShellApplication {
    name = "claude";
    runtimeInputs = [
      coreutils
      util-linux
      jq
    ];
    text = ''
      ${pathPrefix}
      # Without a config folder, run on the ~/.claude-* account with the most
      # weekly usage left per hour until its reset, from the rate-limits.json
      # the status line saves; a full 5h window scores 0, no file a fresh week.
      # All accounts share ~/.claude/projects: sessions, resume and memory.
      if [ -z "''${CLAUDE_CONFIG_DIR:-}" ]; then
        best=-1
        for dir in "$HOME"/.claude-*/; do
          [ -f "$dir.credentials.json" ] || continue
          score=$(jq '
            if (.five_hour.resets_at // 0) > now and .five_hour.used_percentage >= 100 then 0
            elif (.seven_day.resets_at // 0) > now
            then (100 - .seven_day.used_percentage) / ([(.seven_day.resets_at - now) / 3600, 1] | max)
            else 100 / 168 end' "$dir/rate-limits.json" 2>/dev/null) && [ -n "$score" ] || score=0.6
          if jq -en "$score > $best" >/dev/null; then
            best=$score
            export CLAUDE_CONFIG_DIR=''${dir%/}
          fi
        done
      fi
      case "''${CLAUDE_CONFIG_DIR:-}" in
        "$HOME"/.claude-*)
          [ -e "$CLAUDE_CONFIG_DIR/projects" ] ||
            ln -sn "$HOME/.claude/projects" "$CLAUDE_CONFIG_DIR/projects" 2>/dev/null || true
          ;;
      esac
      ${ownedSettings ''"''${CLAUDE_CONFIG_DIR:-$HOME/.claude}"'' {
        "settings.json" = claudeSettings;
      }}
      # Subcommands reject session flags.
      case "''${1:-}" in
        mcp | plugin | plugins | update | upgrade | install | doctor | auth | setup-token)
          exec ${lib.getExe claude-code} "$@" ;;
      esac
      # TODO: --plugin-dir rather than a --settings directory marketplace,
      # because Claude keeps a marketplace's old store path for the first launch
      # after a rebuild and drops EGM's agents (2.1.330, no upstream issue as of
      # 2026-11). Switch once it follows the new path on that launch.
      ${execFor (lib.getExe claude-code) claudeArgs}
    '';
  };

  codex = writeShellApplication {
    name = "codex";
    runtimeInputs = [
      coreutils
      util-linux
      jq
    ];
    text = ''
      ${pathPrefix}
      ${ownedSettings ''"''${CODEX_HOME:-$HOME/.codex}"'' codexOwnedSettings}
      # TODO: Codex loads plugins only from real copies under
      # plugins/cache/<marketplace>/<name>/<version> and silently skips symlinks
      # into the store (0.170, no upstream issue as of 2026-11). Drop the copy
      # once it loads a plugin in place. Locked, as parallel launches would race.
      cache=''${CODEX_HOME:-$HOME/.codex}/plugins/cache
      mkdir -p "$cache"
      exec {lock}>"$cache/.${name}.lock"
      flock "$lock"
      if [ "$(cat "$cache/${name}/.nix-source" 2>/dev/null)" != ${marketplace} ]; then
        tmp=$(mktemp -d "$cache/.${name}.XXXXXX")
        for plugin in ${lib.escapeShellArgs (lib.attrNames codexPlugins)}; do
          src=${marketplace}/plugins/$plugin
          version=$(jq -r .version "$src/.codex-plugin/plugin.json")
          mkdir -p "$tmp/$plugin"
          cp -rL --no-preserve=mode "$src"/. "$tmp/$plugin/$version"
        done
        echo ${marketplace} > "$tmp/.nix-source"
        rm -rf "$cache/${name}"
        mv -T "$tmp" "$cache/${name}"
      fi
      exec {lock}>&-
      ${execFor (lib.getExe codex) codexArgs}
    '';
  };
}
