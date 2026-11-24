# Prints the config folder a Claude Code session runs in: $CLAUDE_CONFIG_DIR
# if set, else the account with the most of its week left per hour until the
# week resets, so usage that would lapse at the reset goes first. An account
# with a used-up 5-hour or weekly window goes last.
#
# An account is a ~/.claude-*/ folder with a sign-in. Its usage is the
# rate-limits.json the status line saves there from what Claude Code shows it,
# so it is as recent as the account's last session on this host; a window past
# its reset counts as unused, and so does an account with no file yet.
#
# The account folder links every folder of ~/.claude (and CLAUDE.md), so
# sessions, resume and memory are the same on every account. Files stay per
# account: the sign-in, history.jsonl (Claude Code won't read it through a
# link) and settings.json (the wrapper rewrites it at launch).
#
# Any such folder in ~ is used, which is fine while whatever could create one
# could as well rewrite an account's sign-in. If the bwrap wrappers ever keep
# sessions out of the account folders but not ~/.claude, list the accounts in
# Nix instead.

set -euo pipefail
shopt -s nullglob

dir=${CLAUDE_CONFIG_DIR:-}
if [ -z "$dir" ]; then
  dir=$(
    for d in "$HOME"/.claude-*/; do
      [ -f "$d.credentials.json" ] || continue
      jq -c --arg dir "${d%/}" '{dir: $dir, limits: .}' "$d/rate-limits.json" 2>/dev/null ||
        jq -nc --arg dir "${d%/}" '{dir: $dir}'
    done | jq -rs '
      def hours($w): if ($w.resets_at // 0) > now then ($w.resets_at - now) / 3600 else null end;
      def left($w): if hours($w) then 100 - ($w.used_percentage // 0) else 100 end;
      map(.limits as $l | . + (try {
        full: (left($l.five_hour) <= 0 or left($l.seven_day) <= 0),
        score: (left($l.seven_day) / ([hours($l.seven_day) // 168, 1] | max))
      } catch {full: false, score: 0}))
      | sort_by(.full, -.score) | .[0].dir // empty'
  )
fi

case $dir in
  "$HOME"/.claude-*)
    for src in "$HOME"/.claude/*/ "$HOME/.claude/CLAUDE.md"; do
      src=${src%/} name=${src##*/}
      case $name in backups | cache | daemon*) continue ;; esac
      # -n: a launch racing this one may have just made the link, which plain
      # ln would follow and link inside ~/.claude.
      [ ! -e "$src" ] || [ -e "$dir/$name" ] || ln -sfn "$src" "$dir/$name" 2>/dev/null || true
    done
    ;;
esac

echo "$dir"
