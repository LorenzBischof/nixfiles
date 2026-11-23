# Claude Code's status line: whether the prompt cache is still warm, from the
# `prompt_cache` object Claude Code hands the status line (v2.1.251+). Claude
# Code re-runs it when a warm cache reaches `expires_at`, so it turns cold on
# its own, without a refresh interval.
#
# Inside a herdr-core terminal it also keeps the expiry in the terminal's
# `claude.cache_expires` label (epoch seconds, removed while cold), where the
# Herdr app's mods read it. It writes only on a change, so a render costs no
# hc call.
{
  writeShellApplication,
  jq,
  coreutils,
}:
writeShellApplication {
  name = "claude-statusline";
  runtimeInputs = [
    jq
    coreutils
  ];
  text = ''
    read -r warm expires recache < <(jq -r '
      .prompt_cache // {} |
      [ (.warm // false), (.expires_at // 0), (.recache_tokens_if_cold // 0) ] | @tsv') || true

    now=$(date +%s)
    if [[ $warm == true && $expires -gt $now ]]; then
      echo "cache warm until $(date -d "@$expires" +%H:%M)"
    else
      expires=""
      if [[ $recache -gt 0 ]]; then
        echo "cache cold · $(( (recache + 500) / 1000 ))k to re-cache"
      fi
    fi

    # hc is on PATH inside herdr-core terminals; elsewhere there is nothing to label.
    [[ -n ''${HC_TERMINAL_ID-} ]] && command -v hc >/dev/null || exit 0
    state=''${XDG_RUNTIME_DIR:-/tmp}/claude-statusline
    mkdir -p "$state"
    last=$state/$HC_TERMINAL_ID
    [[ $(cat "$last" 2>/dev/null) == "$expires" ]] && exit 0
    if hc label "$HC_TERMINAL_ID" "claude.cache_expires=$expires" >/dev/null 2>&1; then
      printf '%s' "$expires" >"$last"
    fi
  '';
}
