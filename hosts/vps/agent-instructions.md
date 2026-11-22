# Environment

You are running as the `agent` user on a NixOS machine. This whole environment is defined in [nixfiles](https://github.com/LorenzBischof/nixfiles) (forked to `lorenzbischof-agents/nixfiles`, and cloned to `~/nixfiles`). That includes the installed packages, git config, secrets, this file, and tools such as `codex` and `hc` (herdr-core). The `agent` user itself is defined in `hosts/vps/ovis.nix`, this file in `hosts/vps/agent-instructions.md`, and the Claude Code and Codex wrappers (with their skills, plugins and MCP servers) in `modules/nixos/agents/`.

If you need a tool that isn't installed, use `nix-shell`. Don't install anything permanently (`nix profile install`, `npm -g`, etc.):

```bash
nix-shell -p jq ripgrep --run 'jq --version && rg --version'   # one-off command
nix-shell -p jq ripgrep                                        # interactive shell with the tools
```

If something is missing or misconfigured *permanently* (a tool you'll keep needing, a broken config, a startup warning), suggest fixing it in nixfiles and opening a PR. Don't suggest this for one-off tools; `nix-shell` covers those. Ask the user first, and if they agree, hand the work off to a separate agent with `hc` so your current task isn't interrupted.

## Changing a repository

Never edit the main checkout (e.g. `~/nixfiles`); other agents may be using it. Work in a fresh worktree:

```bash
git -C ~/REPO fetch origin
git -C ~/REPO worktree add ~/.herdr/worktrees/REPO/BRANCH -b BRANCH origin/main
```

(`/` in a branch name becomes `-` in the folder; this is where Ovis looks.) When handing work to another agent, create its worktree first and start it there with `--cwd`.

Nix flakes only see files git tracks: `git add` new files before `nix build` or `nix flake check`.

When the worktree is clean and its commits are pushed, remove it with `git worktree remove`. Keep the branch if it has commits; delete it (`git branch -d`) if it has none. Don't force-remove a worktree with uncommitted changes without asking.

# GitHub

`git` and `gh` are already authenticated. Don't set `GH_TOKEN`, don't run `gh auth login`, and never read, print or copy a token. Both tools use the `lorenzbischof-agents` org token (full access to the org) for repos in `lorenzbischof-agents`, and a personal token (read contents and open PRs on `LorenzBischof` repos, read public repos anywhere) for everything else. So:

- You can clone and fetch any public repo and any `LorenzBischof` repo, private ones included.
- You can push only to repos in `lorenzbischof-agents`. Forks always go there.
- `gh` uses the org token for `gh repo fork` and for calls with an argument that starts with an org repo: `-R lorenzbischof-agents/REPO`, `repos/lorenzbischof-agents/…` in `gh api`, or a `https://github.com/lorenzbischof-agents/…` URL. Everything else, including `gh pr create --head lorenzbischof-agents:BRANCH`, uses the personal token.

## Contributing

Clone the original repo, so `origin` is upstream, and push to the fork:

```bash
git remote add fork https://github.com/lorenzbischof-agents/REPO.git
git config remote.pushDefault fork
```

Keep the fork in sync with git, not `gh repo sync`: `git fetch origin && git push fork origin/main:main`.

How to fork and how to open the PR depends on whose repo it is:

| Repo | Fork | PR |
|---|---|---|
| `LorenzBischof`, public | `gh repo fork LorenzBischof/REPO --org lorenzbischof-agents --clone=false` | `gh pr create -R LorenzBischof/REPO --head lorenzbischof-agents:BRANCH` |
| `LorenzBischof`, private | the user forks it: give them `https://github.com/LorenzBischof/REPO/fork` and wait | the user opens it: give them the compare link |
| anyone else's | `gh repo fork OWNER/REPO --org lorenzbischof-agents --clone=false` | the user opens it: give them the compare link |

The compare link opens GitHub's PR form with title and body prefilled; URL-encode both:

```
https://github.com/OWNER/REPO/compare/BASE...lorenzbischof-agents:REPO:BRANCH?expand=1&title=TITLE&body=BODY
```

```bash
jq -rn --arg t "$TITLE" --arg b "$BODY" '"…?expand=1&title=\($t|@uri)&body=\($b|@uri)"'
```

You can't edit a PR the user opened, or comment on it; push new commits to the branch instead.

### After giving a compare link

Don't stop at the link. Start a Monitor that waits for the user to open the PR, then reports each check as it finishes and exits once none are pending. A Monitor runs for at most 30 minutes, so set `timeout_ms` to 1800000 and re-arm it each time it expires. Give up 2 hours after the first arm. Note the time with `date +%s` when you first arm it, add 7200, and put the result in `deadline` unchanged in every re-arm:

```bash
deadline=EPOCH; head=lorenzbischof-agents:BRANCH; prev=""
past() { [ "$(date +%s)" -ge "$deadline" ] && { echo "gave up: 2h deadline reached"; exit 0; }; }
until pr=$(gh pr list -R OWNER/REPO --head "$head" --state all --json number,url -q '.[0] | select(.) | "\(.number) \(.url)"' 2>/dev/null) && [ -n "$pr" ]; do past; sleep 60; done
echo "PR opened: ${pr#* }"; n=${pr%% *}
while true; do
  past
  s=$(gh pr checks "$n" -R OWNER/REPO --json name,bucket 2>/dev/null) || { sleep 60; continue; }
  cur=$(jq -r '.[] | select(.bucket!="pending") | "\(.name): \(.bucket)"' <<<"$s" | sort)
  comm -13 <(echo "$prev") <(echo "$cur"); prev=$cur
  [ "$s" != "[]" ] && jq -e 'all(.bucket!="pending")' <<<"$s" >/dev/null && { echo "all checks done"; break; }
  sleep 60
done
```

If it gives up, tell the user what was still pending. If a check fails, read its log (`gh run view --log-failed`), find the cause and propose a fix. Push the fix only to a fork of a `LorenzBischof` repo; for anyone else's repo, show the change and wait for the user to say push.
