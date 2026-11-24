# Claude Code and Codex wrappers that pass the setup as launch flags where the
# CLIs take one, so what users add by hand keeps working. Settings that other
# readers need too (plugin hooks and skills read the files, never the flags)
# are merged into the user's files at launch instead, see ownedSettings below.
# Our skills ship as one more plugin, so both CLIs load everything the
# same way, at the price of a namespace (`nixos:grill-me`). Instructions are
# left to ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md and the repositories.
{
  lib,
  runCommand,
  linkFarm,
  writeShellApplication,
  writeText,
  coreutils,
  util-linux,
  jq,
  curl,
  claude-code,
  codex,
  # In nixpkgs' installAgentSkills layout; their bin/ goes on PATH.
  skillPackages,
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

  skillsPlugin = runCommand "${name}-skills-plugin" { } ''
    mkdir -p $out/skills $out/.claude-plugin $out/.codex-plugin
    for pkg in ${lib.escapeShellArgs skillPackages}; do
      cp -rL "$pkg"/share/skills/*/* $out/skills/
    done
    echo ${lib.escapeShellArg (builtins.toJSON manifest)} > $out/.claude-plugin/plugin.json
    echo ${
      lib.escapeShellArg (builtins.toJSON (manifest // { skills = "./skills/"; }))
    } > $out/.codex-plugin/plugin.json
  '';

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
    // {
      ${name} = {
        claude = skillsPlugin;
        codex = skillsPlugin;
      };
    };
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

  codexSettings = lib.recursiveUpdate {
    # Codex has no `type`; it tells the transport from `url` or `command`.
    mcp_servers = lib.mapAttrs (_: server: removeAttrs server [ "type" ]) mcpServers;
    features.plugins = true;
    marketplaces.${name} = {
      source_type = "local";
      source = "${marketplace}";
    };
    plugins = lib.mapAttrs' (
      plugin: _: lib.nameValuePair "${plugin}@${name}" { enabled = true; }
    ) codexPlugins;
  } codexConfig;

  codexArgs = lib.concatLists (
    lib.mapAttrsToList (key: value: [
      "-c"
      "${key}=${toToml value}"
    ]) codexSettings
  );

  # --mcp-config takes several values; --settings after it ends the list, so a
  # prompt is not read as one.
  claudeArgs = [
    "--mcp-config"
    (builtins.toJSON { inherit mcpServers; })
    "--settings"
    (builtins.toJSON claudeFlagSettings)
  ]
  ++ lib.concatMap (dir: [
    "--plugin-dir"
    "${dir}"
  ]) (lib.attrValues claudePlugins);

  pathPrefix = ''
    export PATH=${lib.makeBinPath skillPackages}:"$PATH"
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

  claudeAccount = writeShellApplication {
    name = "claude-account";
    runtimeInputs = [
      coreutils
      util-linux
      jq
      curl
    ];
    text = builtins.readFile ./claude-account.sh;
  };
in
{
  claude-account = claudeAccount;

  claude = writeShellApplication {
    name = "claude";
    runtimeInputs = [
      coreutils
      util-linux
      jq
    ];
    text = ''
      ${pathPrefix}
      # A session started without a config folder runs on the account
      # claude-account ranks first; a folder chosen by hand or by Ovis's sign-in
      # stays. Signing in picks none, so it goes where it was asked to.
      case "''${1:-}" in
        auth | setup-token) ;;
        *)
          if [ -z "''${CLAUDE_CONFIG_DIR:-}" ]; then
            dir=$(${lib.getExe claudeAccount} pick 2>/dev/null) || dir=""
            [ -z "$dir" ] || export CLAUDE_CONFIG_DIR="$dir"
          fi
          ;;
      esac
      case "''${CLAUDE_CONFIG_DIR:-}" in
        "$HOME"/.claude-*) ${lib.getExe claudeAccount} link "$CLAUDE_CONFIG_DIR" || true ;;
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
      exec ${lib.getExe claude-code} ${lib.escapeShellArgs claudeArgs} "$@"
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
      exec ${lib.getExe codex} ${lib.escapeShellArgs codexArgs} "$@"
    '';
  };
}
