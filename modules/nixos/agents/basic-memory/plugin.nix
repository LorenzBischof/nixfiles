# Basic Memory for the agent wrappers: the CLI with its environment baked in,
# and upstream's Claude Code and Codex plugins with the MCP server, the hooks
# and the memory-* skills pointed at it.
{
  lib,
  runCommand,
  writeText,
  symlinkJoin,
  writeShellApplication,
  writeShellScriptBin,
  jq,
  basicMemory,
  # Where the notes and the SQLite index and config live, relative to each
  # user's $HOME.
  notesDir,
  stateDir,
}:
let
  # Defaults rather than overrides, so `BASIC_MEMORY_HOME=... bm` still works.
  # Resolved per user at runtime, which is why none of this sits in a .mcp.json
  # `env` block.
  envScript = ''
    export BASIC_MEMORY_HOME="''${BASIC_MEMORY_HOME:-$HOME/${notesDir}}"
    # Declared rather than inherited: `resolve_data_dir` prefers this, then
    # $XDG_CONFIG_HOME/basic-memory, then ~/.basic-memory, and an XDG_CONFIG_HOME
    # would point at an empty state dir, every project needing a re-add.
    export BASIC_MEMORY_CONFIG_DIR="''${BASIC_MEMORY_CONFIG_DIR:-$HOME/${stateDir}}"
    # Pin telemetry off even if upstream changes its defaults.
    export BASIC_MEMORY_LOGFIRE_ENABLED=false
    export BASIC_MEMORY_LOGFIRE_SEND_TO_LOGFIRE=false
    # The version comes from the flake input; a PyPI update check could only
    # ever nag, never apply.
    export BASIC_MEMORY_AUTO_UPDATE=false
    # Rerank search hits with a local cross-encoder (jina-reranker-v1-tiny-en,
    # fetched once into the fastembed cache in the state dir): it puts the right
    # note first where embedding distance alone picks a schema or a tangent.
    export BASIC_MEMORY_RERANKER_ENABLED=true
  '';
  wrap =
    bin:
    writeShellScriptBin bin ''
      ${envScript}
      exec ${basicMemory}/bin/${bin} "$@"
    '';
  cli = wrap "basic-memory";

  # Upstream's hooks.json runs a Python launcher per hook through
  # `uv run --script`, resolving basic-memory and fastmcp from PyPI at every
  # session start. Each launcher only turns its own filename into
  # `basic-memory hook <verb>`, so this runner does that from the packaged CLI
  # and takes the launcher's path as its one argument, standing in for every
  # hook the plugin ships, present and future.
  hookRunner =
    harness:
    writeShellApplication {
      name = "basic-memory-hook-${harness}";
      runtimeInputs = [ cli ];
      # No --project-dir, which upstream's Claude launcher passes from
      # CLAUDE_PROJECT_DIR: it only overrides the cwd the harness already sends
      # in the payload.
      #
      # A failure inside a verb already exits 0 through the CLI's own fail-open
      # path, so what reaches here is a packaging bug worth seeing. Not passed
      # through verbatim: typer exits 2 on a usage error, and 2 is the one code
      # PreCompact treats as blocking.
      text = ''
        # ".../hooks/pre_compact.py" -> `basic-memory hook pre-compact`.
        verb=$(basename "''${1:-}" .py)
        basic-memory hook "''${verb//_/-}" --harness ${harness} || exit 1
      '';
    };

  package = symlinkJoin {
    name = "basic-memory-${basicMemory.version}";
    paths = [
      cli
      (wrap "bm")
    ];
    meta.mainProgram = "basic-memory";
  };

  mcpJson =
    extra:
    writeText "basic-memory-mcp.json" (
      builtins.toJSON {
        mcpServers.basic-memory = {
          command = lib.getExe package;
          args = [ "mcp" ];
        }
        // extra;
      }
    );

  # From the package source, so the bm-* skills, the output style and the
  # manifests follow the MCP server's version. `--replace-fail` so a release
  # that stops shipping the uv prefix fails the build instead of reaching for
  # uv. The memory-* skills sit outside upstream's plugins (it expects
  # `npx skills add`); carrying them here keeps them in lockstep too.
  mkPlugin =
    {
      pluginDir,
      harness,
      mcp ? { },
      extraSetup ? "",
    }:
    runCommand "basic-memory-${harness}-plugin" { nativeBuildInputs = [ jq ]; } ''
      cp -r ${basicMemory.src}/plugins/${pluginDir} $out
      chmod -R u+w $out
      substituteInPlace $out/hooks/hooks.json \
        --replace-fail 'uv run --quiet --script' ${lib.getExe (hookRunner harness)}
      cp -r ${basicMemory.src}/skills/memory-* $out/skills/
      cp ${mcpJson mcp} $out/.mcp.json
      ${extraSetup}
    '';
in
{
  inherit package;
  plugin = {
    claude = mkPlugin {
      pluginDir = "claude-code";
      harness = "claude";
    };
    codex = mkPlugin {
      pluginDir = "codex";
      harness = "codex";
      mcp.required = true;
      # Upstream calls it "codex"; the wrapper's cache layout and the
      # `<name>@nixos` key expect the name it is registered under.
      extraSetup = ''
        jq '.name = "basic-memory"' $out/.codex-plugin/plugin.json > manifest.json
        mv manifest.json $out/.codex-plugin/plugin.json
      '';
    };
  };
}
