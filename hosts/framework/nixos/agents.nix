{ lib, pkgs, ... }:
let
  # Ring the terminal bell when a Codex turn finishes.
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
in
{
  my.programs.agents = {
    enable = true;
    browser = pkgs.google-chrome;
    # The notes follow the laptop through the syncthing folder shared with nas;
    # the SQLite index and config stay local in ~/.basic-memory, since the index
    # rebuilds from the markdown and syncing it would only produce conflicts.
    basicMemory = {
      enable = true;
      notesDir = "files-lo/memory";
    };
    codex.config = {
      notify = [ (lib.getExe codexNotify) ];
      sandbox_mode = "workspace-write";
      sandbox_workspace_write.network_access = true;
      approval_policy = "on-request";
      approvals_reviewer = "auto_review";
    };
  };
}
