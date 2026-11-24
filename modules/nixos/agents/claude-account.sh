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
# keep their sign-ins out of the sandbox's reach. Once the accounts have moved
# out of it, ~/.claude holds no sign-in: sessions, memory, plugins and the rest
# live there once, and every account folder links to them, so a session
# resumes and remembers the same on any account. Files stay per account, among
# them the sign-in (.credentials.json, and .claude.json, which names its
# account and the folders it trusts), history.jsonl, which Claude Code refuses
# to read through a link (2.1.331), and settings.json, which the wrapper
# rewrites at every launch.

set -euo pipefail
shopt -s nullglob dotglob

shared=$HOME/.claude
cache=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-account

dirs() {
  local dir
  for dir in "$HOME"/.claude-*/; do
    [ -f "$dir.credentials.json" ] && echo "${dir%/}"
  done
  return 0
}

# Asks api/oauth/usage for one account and caches the answer. Read only: the
# token is never refreshed here, since Claude Code rotates refresh tokens and
# a refresh it did not make signs it out. An access token lasts about 8 hours,
# so an account nobody used since is cached as {"expired": true}, and the next
# session on it refreshes the token. No token, or a failed request, is null.
fetch() {
  local dir=$1 file token body=null
  file=$cache/${dir##*/}.json
  token=$(jq -r '.claudeAiOauth |
      if (.accessToken // "") == "" then ""
      elif (.expiresAt // 0) > now * 1000 then .accessToken
      elif (.refreshToken // "") != "" then "expired"
      else "" end' "$dir/.credentials.json" 2>/dev/null) || token=""
  if [ "$token" = expired ]; then
    body='{"expired":true}'
  elif [ -n "$token" ]; then
    # The header goes in on stdin, so the token is never in an argument list.
    body=$(curl -fsS -m 5 -H @- -H 'anthropic-beta: oauth-2025-04-20' -H 'accept: application/json' \
      https://api.anthropic.com/api/oauth/usage <<<"Authorization: Bearer $token" 2>/dev/null |
      jq -ce objects) || body=null
  fi
  echo "$body" >"$file.tmp.$$"
  mv -f "$file.tmp.$$" "$file"
}

# Whether an account's cached answer is due again: an answer after 5 minutes,
# no answer or an expired token after 1, as a session may have refreshed it.
old() {
  local file=$1 keep
  [ -f "$file" ] || return 0
  keep=$(jq -r 'if type == "object" and (has("expired") | not) then 300 else 60 end' "$file" 2>/dev/null) || keep=0
  [ $(($(date +%s) - $(stat -c %Y "$file"))) -ge "$keep" ]
}

# Fetches every account whose answer is due, all at once. One refresh at a
# time: in the background a refresh already running is left to finish; with
# `wait` it is waited for, up to 20 seconds.
refresh() {
  local dir lock
  install -d -m 700 "$cache"
  exec {lock}>"$cache/lock"
  if [ "${1:-}" = wait ]; then
    flock -w 20 "$lock" || return 0
  else
    flock -n "$lock" || return 0
  fi
  for dir in $(dirs); do
    if old "$cache/${dir##*/}.json"; then
      fetch "$dir" &
    fi
  done
  wait
}

stale() {
  local dir
  for dir in $(dirs); do
    old "$cache/${dir##*/}.json" && return 0
  done
  return 1
}

# Ranks the accounts from the cache, best first. An account with a used-up
# window (5-hour, weekly, or a model's weekly) goes last, the one that frees up
# first ahead of the others. The rest are ranked by what is left of their week
# per hour until it resets, so usage that would otherwise lapse unused at the
# reset goes first. An account whose token expired counts as a fresh week:
# it was likely idle, and a session there is what refreshes the token. One
# without an answer goes after those with one: it may be signed out.
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
        (if .usage.expired == true then {} else .usage // {} end) as $u
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
# only reads. Other files stay per account: one that Claude Code replaces by a
# rename would turn its link back into a file. So do backups/, copies of the
# account's .claude.json, and cache/, what Claude Code read for its plan.
link() {
  local dir=$1 src name dst apart=() warned
  for src in "$shared"/*/ "$shared"/CLAUDE.md; do
    src=${src%/}
    [ -e "$src" ] || continue
    name=${src##*/}
    case $name in backups | cache | daemon*) continue ;; esac
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
  if [ ${#apart[@]} -gt 0 ] && [ ! -e "$warned" ] && install -d -m 700 "$cache" 2>/dev/null; then
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
