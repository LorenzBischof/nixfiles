#!/usr/bin/env bash
# nixos-upgrade-doctor: diagnose why a host's nixos-upgrade auto-upgrade is stuck.
#
# Usage:
#   just upgrade-doctor                                 # this machine (no SSH)
#   just upgrade-doctor <host>                          # e.g. nas, vps
#   scripts/nixos-upgrade-doctor.sh [host]              # same, directly
#   scripts/nixos-upgrade-doctor.sh --rev <sha> [host]  # analyse a known rev locally
#
# Emits a short narrative: what's deployed, what happened to it, and the fix.
# Exit codes: 0 ran; 2 usage; 3 blocked by the bwrap sandbox (SSH unavailable).
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" || exit 2
slug="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@|https://)[^:/]+[:/]##; s#\.git$##')"
: "${slug:=lorenzbischof/nixfiles}"

# No host (or empty) means this machine, like `just switch` — run locally, no SSH.
rev=""; host=""; islocal=0
if [ "${1:-}" = "--rev" ]; then
  rev="${2:?--rev needs a sha}"; host="${3:-$(hostname 2>/dev/null || echo local)}"
elif [ -z "${1:-}" ]; then
  islocal=1; host="$(hostname 2>/dev/null || echo local)"
else
  host="$1"
fi

# report <headline> [detail] [fix]  — the whole output, 1-3 short lines.
report() { echo "$1"; [ -n "${2:-}" ] && echo "  ↳ $2"; [ -n "${3:-}" ] && echo "  Fix: $3"; exit 0; }

# probe <snippet> — run a shell snippet on the target: locally, or over SSH.
probe() { if [ "$islocal" = 1 ]; then bash -c "$1"; else ssh "$host" "$1"; fi; }

# ---- sandbox gate: inside claude-bwrap, PID 1 is bwrap and SSH cannot work ----
# Only blocks the remote path; local mode needs no SSH.
if [ -z "$rev" ] && [ "$islocal" = 0 ] && tr '\0' ' ' < /proc/1/cmdline 2>/dev/null | grep -q '\bbwrap\b'; then
  echo "BLOCKED: running inside the claude-bwrap sandbox — no ~/.ssh config/known_hosts/agent, so SSH fails."
  echo "  Fix: relaunch the plain 'claude' binary (not claude-bwrap), then re-run."
  echo "  Or skip SSH:  scripts/nixos-upgrade-doctor.sh --rev <deployed-sha> $host"
  exit 3
fi

# ---- 1. host: service state + deployed rev (single round-trip) ---------------
if [ -z "$rev" ]; then
  # Ask systemd for machine-readable state and append the deployed rev as one more
  # key=value line, so the whole reply parses uniformly (and, when remote, it's a
  # single SSH round-trip / YubiKey tap).
  out="$(probe 'systemctl show nixos-upgrade.service -p ActiveState,Result 2>/dev/null; printf "GitRevision=%s\n" "$(nixos-version --configuration-revision 2>/dev/null)"' 2>/dev/null)"
  kv() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
  rev="$(kv GitRevision | tr -d '[:space:]')"
  state="$(kv ActiveState)"; result="$(kv Result)"
  echo "nixos-upgrade on $host: ${state:-unknown}${result:+ ($result)}"
  [ -z "$rev" ] && report "could not read deployed rev ($host: nixos-version --configuration-revision is empty)"
fi

# A dirty rev never comes from auto-upgrade — it's a manual deploy of uncommitted work.
case "$rev" in
  *-dirty) report "$host runs a dirty build of ${rev%-dirty} (uncommitted changes at deploy time)." \
                  "redeploy from a clean, committed & pushed rev so auto-upgrade can resume." ;;
esac

sha="${rev:0:7}"
desc="$(git log --format=%s -1 "$rev" 2>/dev/null)"; desc="${desc:-(no message)}"

# ---- 2. classify against GitHub (mirrors the ExecCondition guard) -----------
status="$(curl -s "https://api.github.com/repos/$slug/compare/HEAD...$rev" | jq -r '.status // .message // "no-response"')"
case "$status" in
  identical) report "$host runs $sha \"$desc\" — identical to main; auto-upgrade healthy, nothing to do." ;;
  behind)    report "$host runs $sha \"$desc\" — behind main; the next timer run will upgrade. Healthy." ;;
  ahead)     : ;;  # exists on remote but unmerged — analyse below
  404|"Not Found") : ;;  # not on remote — analyse below
  *)         report "$host runs $sha \"$desc\" — GitHub compare inconclusive ($status: rate-limited or bad rev)." ;;
esac

# ---- 3. local jj/git forensics on the orphan --------------------------------
head="$host runs $sha \"$desc\" — not on GitHub."

if ! git cat-file -t "$rev" >/dev/null 2>&1; then
  report "$head" "this checkout has never seen that commit (deployed from another machine / lost working copy)." \
         "redeploy from up-to-date main:  just switch $host"
fi

hidden="$(jj log --no-graph -r "$rev" -T 'if(hidden,"y","n")' 2>/dev/null)"

if [ "$hidden" = y ]; then
  change_id="$(jj log --no-graph -r "$rev" -T 'change_id' 2>/dev/null)"
  cur="$(jj log --no-graph -r "$change_id" -T 'commit_id' 2>/dev/null)"
  curdesc="$(jj log --no-graph -r "$change_id" -T 'description.first_line()' 2>/dev/null)"; curdesc="${curdesc:-(no message)}"
  # the verb of the op that rewrote it, e.g. "squash" / "rebase" / "describe"
  op="$(jj evolog --no-graph -r "$rev" 2>/dev/null | sed -nE 's/.*operation [0-9a-f]+ ([a-z]+).*/\1/p' | head -1)"
  if [ -n "$cur" ] && git merge-base --is-ancestor "$cur" origin/main 2>/dev/null; then
    report "$head" \
      "you deployed a pre-${op:-rewrite} snapshot; jj later rewrote that change into ${cur:0:7} \"$curdesc\" (now on main), orphaning the deployed hash — so the guard skips every run." \
      "redeploy from up-to-date main:  just switch $host"
  else
    report "$head" \
      "jj rewrote this commit into ${cur:0:7} \"$curdesc\", which isn't on main yet." \
      "publish it, then redeploy:  jj bookmark set main -r ${cur:0:7} && jj git push ; just switch $host"
  fi
elif [ "$status" = "ahead" ]; then
  report "$host runs $sha \"$desc\" — on the remote but ahead of main (unmerged)." \
    "it lives on a branch/PR that never merged." \
    "merge that PR; no redeploy needed since $host already runs this commit."
else
  report "$head" \
    "it's a real local commit you switched onto $host but never pushed; $host already runs this content." \
    "publish it — no redeploy needed:  jj bookmark set main -r $sha && jj git push"
fi
