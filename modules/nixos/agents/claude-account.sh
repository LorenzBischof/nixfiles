# Chooses the Claude Code account a new session runs on, and keeps every
# account's folder sharing one state with the others.
#
#   claude-account pick       prints the config folder to run in, or nothing
#   claude-account usage      prints every account with its usage and rank, as JSON
#   claude-account link DIR   links DIR's shared entries to ~/.claude
#
# An account is a ~/.claude-*/ folder holding a .credentials.json. ~/.claude
# holds no sign-in: sessions, memory, plugins and the rest live there once, and
# each account folder links to them, so a session resumes and remembers the
# same on any account. Only the sign-in and what Claude Code refuses to read
# through a link stay per account (see `own` below).

set -euo pipefail
shopt -s nullglob

shared=$HOME/.claude
cache=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-account

accounts() {
  local dir
  for dir in "$HOME"/.claude-*/; do
    [ -f "$dir.credentials.json" ] && echo "${dir%/}"
  done
  return 0
}

# One account's answer from api/oauth/usage, or null when there is none: no
# token, an expired one, or a failed request. Read only: the token is never
# refreshed here, since Claude Code rotates refresh tokens and a refresh it
# did not make signs it out. An expired token is refreshed by the next session
# on that account. Answers are kept 5 minutes, failures 1, and parallel
# launches wait for one request rather than each making their own.
usage_of() {
  local dir=$1 file lock age token body ok
  file=$cache/${dir##*/}.json
  mkdir -p "$cache" && chmod 700 "$cache"
  exec {lock}>"$file.lock"
  flock "$lock"
  if [ -f "$file" ]; then
    age=$(($(date +%s) - $(stat -c %Y "$file")))
    if [ "$age" -lt "$(jq -r 'if .usage == null then 60 else 300 end' "$file" 2>/dev/null || echo 0)" ]; then
      jq -c .usage "$file"
      exec {lock}>&-
      return
    fi
  fi
  body=null
  token=$(jq -r '.claudeAiOauth | select((.expiresAt // 0) > now * 1000) | .accessToken // empty' \
    "$dir/.credentials.json" 2>/dev/null || true)
  if [ -n "$token" ]; then
    # The header goes in on stdin, so the token is never in an argument list.
    if ok=$(curl -fsS -m 5 -H @- -H 'anthropic-beta: oauth-2025-04-20' -H 'accept: application/json' \
      https://api.anthropic.com/api/oauth/usage <<<"Authorization: Bearer $token" 2>/dev/null) &&
      jq -e 'type == "object"' >/dev/null 2>&1 <<<"$ok"; then
      body=$ok
    fi
  fi
  jq -n -c --argjson usage "$body" '{usage: $usage}' >"$file.tmp"
  mv -f "$file.tmp" "$file"
  jq -c . <<<"$body"
  exec {lock}>&-
}

# Ranks the accounts, best first. An account whose 5-hour or weekly window is
# used up goes last, the one that frees up first ahead of the others. The rest
# are ranked by what is left of their week per hour until it resets, so usage
# that would otherwise lapse unused at the reset goes first. An account
# without an answer counts as a fresh week: plenty left, no hurry.
usage() {
  local dir
  for dir in $(accounts); do
    jq -n -c --arg dir "$dir" --argjson usage "$(usage_of "$dir")" '{dir: $dir, usage: $usage}'
  done | jq -s '
    def ts: if type == "string" then sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 else null end;
    now as $now
    | map(
        (.usage // {}) as $u
        | ([$u.five_hour, $u.seven_day] | map(select((.utilization // 0) >= 100) | (.resets_at | ts) // $now)) as $full
        | ((($u.seven_day.resets_at | ts) // ($now + 7 * 86400)) - $now) / 3600 as $hours
        | . + {
            score: ((100 - ($u.seven_day.utilization // 0)) / ([$hours, 1] | max)),
            full_until: (if $full == [] then null else ($full | max) end)
          })
    | sort_by([.full_until != null, .full_until // 0, -.score])'
}

# Kept per account: the sign-in (.credentials.json, and .claude.json, which
# names the account it belongs to), history.jsonl, which Claude Code refuses
# to read or write through a link (2.1.331), settings.json, which the wrapper
# replaces with a file at every launch, and backups of .claude.json.
own() {
  case $1 in
    .credentials.json | .claude.json | history.jsonl | settings.json | backups | \
      stats-cache.json | mcp-needs-auth-cache.json | daemon*) return 0 ;;
  esac
  return 1
}

link() {
  local dir=$1 src name dst apart=()
  mkdir -p "$shared"
  for src in "$shared"/* "$shared"/.[!.]*; do
    name=${src##*/}
    own "$name" && continue
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
  # own until it is moved into ~/.claude by hand.
  if [ ${#apart[@]} -gt 0 ]; then
    echo "claude-account: not shared with $shared, as $dir has its own: ${apart[*]}" >&2
  fi
}

case ${1:-} in
  pick) usage | jq -r '.[0].dir // empty' ;;
  usage) usage ;;
  link) link "${2:?usage: claude-account link DIR}" ;;
  *)
    echo "usage: claude-account pick | usage | link DIR" >&2
    exit 2
    ;;
esac
