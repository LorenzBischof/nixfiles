# Claude Code's status line: whether the prompt cache is still warm, from the
# `prompt_cache` object Claude Code hands the status line (v2.1.251+). Claude
# Code re-runs it when a warm cache reaches `expires_at`, so it turns cold on
# its own, without a refresh interval.
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
      .prompt_cache |
      [ (.warm // false), (.expires_at // 0), (.recache_tokens_if_cold // 0) ] | @tsv') || true

    now=$(date +%s)
    if [[ $warm == true && $expires -gt $now ]]; then
      echo "cache warm until $(date -d "@$expires" +%H:%M)"
    elif [[ $recache -gt 0 ]]; then
      echo "cache cold · $(( (recache + 500) / 1000 ))k to re-cache"
    fi
  '';
}
