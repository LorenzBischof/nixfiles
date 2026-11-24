# Chooses the Claude Code account a new session runs on, and keeps every
# account's folder sharing one state with the others.
#
#   claude-account pick       prints the config folder to run in; reads only
#                             the cache, so it never waits, and refreshes the
#                             cache in the background when it is stale
#   claude-account usage      refreshes the cache and prints every account with
#                             its usage, best first, as JSON
#   claude-account link DIR   links DIR's shared folders to ~/.claude
#
# An account is any ~/.claude-*/ folder holding a .credentials.json, so a
# sign-in made through Ovis (which creates one) is used without a change here.
# Trusting whatever turns up in ~ costs nothing today: whatever can create such
# a folder can as well rewrite a listed account's sign-in, or ~/.claude's hooks
# and skills. Should the bwrap wrappers ever keep sessions out of the account
# folders while ~/.claude stays writable, list the accounts in Nix instead and
# keep their sign-ins out of the sandbox's reach. ~/.claude holds no
# sign-in: sessions, memory, plugins and the rest live there once, and every
# account folder links to them, so a session resumes and remembers the same
# on any account. Other files stay per account, among them the sign-in (.credentials.json, and
# .claude.json, which names its account and the folders it trusts),
# history.jsonl, which Claude Code refuses to read through a link (2.1.331),
# and settings.json, which the wrapper rewrites at every launch.

set -euo pipefail
shopt -s nullglob dotglob

shared=$HOME/.claude
cache=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-account
fresh=300

dirs() {
  local dir
  for dir in "$HOME"/.claude-*/; do
    [ -f "$dir.credentials.json" ] && echo "${dir%/}"
  done
  return 0
}

# Asks api/oauth/usage for one account and caches the answer, or null when
# there is none: no token, an expired one, or a failed request. Read only: the
# token is never refreshed here, since Claude Code rotates refresh tokens and
# a refresh it did not make signs it out; the next session on that account
# refreshes it.
fetch() {
  local dir=$1 file token body=null
  file=$cache/${dir##*/}.json
  token=$(jq -r '.claudeAiOauth | select((.expiresAt // 0) > now * 1000) | .accessToken // empty' \
    "$dir/.credentials.json" 2>/dev/null) || token=""
  if [ -n "$token" ]; then
    # The header goes in on stdin, so the token is never in an argument list.
    body=$(curl -fsS -m 5 -H @- -H 'anthropic-beta: oauth-2025-04-20' -H 'accept: application/json' \
      https://api.anthropic.com/api/oauth/usage <<<"Authorization: Bearer $token" 2>/dev/null |
      jq -ce objects) || body=null
  fi
  echo "$body" >"$file.tmp.$$"
  mv -f "$file.tmp.$$" "$file"
}

# Fetches every account whose answer is older than $fresh, all at once. One
# refresh at a time: in the background a refresh already running is left to
# finish; with \`wait\` it is waited for, up to 20 seconds.
refresh() {
  local dir file lock
  install -d -m 700 "$cache"
  exec {lock}>"$cache/lock"
  if [ "${1:-}" = wait ]; then
    flock -w 20 "$lock" || return 0
  else
    flock -n "$lock" || return 0
  fi
  for dir in $(dirs); do
    file=$cache/${dir##*/}.json
    if [ ! -f "$file" ] || [ $(($(date +%s) - $(stat -c %Y "$file"))) -ge "$fresh" ]; then
      fetch "$dir" &
    fi
  done
  wait
}

stale() {
  local dir file
  for dir in $(dirs); do
    file=$cache/${dir##*/}.json
    if [ ! -f "$file" ] || [ $(($(date +%s) - $(stat -c %Y "$file"))) -ge "$fresh" ]; then
      return 0
    fi
  done
  return 1
}

# Ranks the accounts from the cache, best first. An account with a used-up
# window (5-hour, weekly, or a model's weekly) goes last, the one that frees up
# first ahead of the others. The rest are ranked by what is left of their week
# per hour until it resets, so usage that would otherwise lapse unused at the
# reset goes first. An account without an answer goes after those with one:
# it may be signed out.
ranked() {
  local dir file
  for dir in $(dirs); do
    file=$cache/${dir##*/}.json
    jq -n -c --arg dir "$dir" '{dir: $dir, usage: ((try input catch null) // null)}' "$file" 2>/dev/null ||
      jq -n -c --arg dir "$dir" '{dir: $dir, usage: null}'
  done | jq -s '
    def ts: try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null;
    now as $now
    | map(
        (.usage // {}) as $u
        | ([$u.five_hour, $u.seven_day, $u.seven_day_opus, $u.seven_day_sonnet]
            | map(select((.utilization // 0) >= 100) | (.resets_at | ts) // ($now + 3600))) as $full
        | (((($u.seven_day.resets_at | ts) // ($now + 7 * 86400)) - $now) / 3600) as $hours
        | . + {
            score: ((100 - ($u.seven_day.utilization // 0)) / ([$hours, 1] | max)),
            full_until: (if $full == [] then null else ($full | max) end)
          })
    | sort_by([.full_until != null, .full_until // 0, .usage == null, -.score])'
}

# Links the folders, and CLAUDE.md, which home-manager writes and Claude Code
# only reads. Other files are left per account: one Claude Code replaces by a
# rename would turn its link back into a file.
link() {
  local dir=$1 src name dst apart=() warned
  for src in "$shared"/*/ "$shared"/CLAUDE.md; do
    src=${src%/}
    [ -e "$src" ] || continue
    name=${src##*/}
    [ "$name" = backups ] && continue
    dst=$dir/$name
    if [ -L "$dst" ]; then
      continue
    elif [ -e "$dst" ]; then
      apart+=("$name")
    else
      ln -s "$src" "$dst"
    fi
  done
  # Something the account made before ~/.claude had it stays the account's
  # own until it is moved into ~/.claude by hand. Said once per boot.
  warned=$cache/${dir##*/}.warned
  if [ ${#apart[@]} -gt 0 ] && [ ! -e "$warned" ] && install -d -m 700 "$cache"; then
    echo "claude-account: not shared with $shared, as $dir has its own: ${apart[*]}" >&2
    touch "$warned"
  fi
}

case ${1:-} in
  pick)
    if stale; then
      setsid "$0" refresh </dev/null >/dev/null 2>&1 &
    fi
    ranked | jq -r '.[0].dir // empty' || dirs | head -n 1
    ;;
  refresh) refresh ;;
  usage)
    refresh wait
    ranked
    ;;
  link) link "${2:?usage: claude-account link DIR}" ;;
  *)
    echo "usage: claude-account pick | usage | link DIR" >&2
    exit 2
    ;;
esac
