# Claude Code's status line: whether the prompt cache is still warm, from the
# `prompt_cache` object Claude Code hands the status line (v2.1.251+). Claude
# Code re-runs it when a warm cache reaches `expires_at`, so it turns cold on
# its own, without a refresh interval.
#
# Inside a herdr-core terminal it also keeps the expiry in the terminal's
# `claude.cache_expires` label (epoch seconds, removed while cold), where the
# Herdr app's mods read it. It writes only on a change, so a render usually
# costs no hc call.
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

    # Outside a herdr-core terminal there is nothing to label.
    [[ -n ''${HC_TERMINAL_ID-} ]] || exit 0
    label() { hc label "$HC_TERMINAL_ID" "claude.cache_expires=$expires" >/dev/null 2>&1; }
    # The last value written is kept only in the private runtime directory, never a shared /tmp.
    if [[ -z ''${XDG_RUNTIME_DIR-} ]]; then
      label || true
      exit 0
    fi
    mkdir -p "$XDG_RUNTIME_DIR/claude-statusline"
    last=$XDG_RUNTIME_DIR/claude-statusline/$HC_TERMINAL_ID
    [[ -e $last && $(<"$last") == "$expires" ]] && exit 0
    # Claude Code cancels a run when the next one starts: forget the old value
    # first, so a run cut off after labelling makes the next one label again.
    rm -f "$last"
    if label; then
      printf '%s' "$expires" >"$last"
    fi
  '';
}
