# Prints the config folder for a Claude Code session: $CLAUDE_CONFIG_DIR, or
# the ~/.claude-* account with the most weekly usage left per hour until its
# reset, read from the rate-limits.json the status line saves. Links the
# folder's state to ~/.claude, so every account shares sessions and memory.
#
# Any ~/.claude-* sign-in is trusted. Should the bwrap wrappers ever hide the
# account folders but not ~/.claude, list the accounts in Nix instead.

set -euo pipefail
shopt -s nullglob

dir=${CLAUDE_CONFIG_DIR:-}
if [ -z "$dir" ]; then
  dir=$(
    for d in "$HOME"/.claude-*/; do
      [ -f "$d.credentials.json" ] || continue
      score=$({ cat "$d/rate-limits.json" 2>/dev/null || echo '{}'; } | jq '
        def live($w): ($w.resets_at // 0) > now;
        def left($w): if live($w) then 100 - $w.used_percentage else 100 end;
        if left(.five_hour) <= 0 then 0
        else left(.seven_day) / (if live(.seven_day) then [(.seven_day.resets_at - now) / 3600, 1] | max else 168 end)
        end' 2>/dev/null) || score=0
      echo "$score ${d%/}"
    done | sort -rg | sed -n '1s/^[^ ]* //p'
  )
fi

# Files stay per account: sign-in, history.jsonl (not read through a link) and
# settings.json (rewritten at launch). -n: a racing launch may have linked it.
case $dir in
  "$HOME"/.claude-*)
    for src in "$HOME"/.claude/*/ "$HOME/.claude/CLAUDE.md"; do
      src=${src%/} name=${src##*/}
      case $name in backups | cache | daemon*) continue ;; esac
      [ ! -e "$src" ] || [ -e "$dir/$name" ] || ln -sfn "$src" "$dir/$name" 2>/dev/null || true
    done
    ;;
esac

echo "$dir"
