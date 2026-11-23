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

### Showing visual changes

When a change alters something you can see — a UI, a bar or desktop element, a theme, a web page, a TUI's output — put a screenshot in the PR body, before and after if the difference is subtle. When the behaviour is in motion (an animation, a dropdown opening, a sequence of states), add a short GIF instead; GitHub won't embed a video linked from a repo, only a GIF. Keep it small: a few seconds and a few MB. Config, refactors and anything without a visible result get no media.

Have a screenshotter capture them:

```bash
hc run --bg screenshotter "Capture CHANGE from BRANCH in REPO_PATH. WHERE_IT_SHOWS. Report with hc send $HC_TERMINAL_ID."
```

It reports local image paths first. Look at each image for anything private, because a pushed image is public and can't be taken back. Then `hc send ADDRESS push`, and it pushes the images to `media/BRANCH` on the fork (never the PR branch) and replies with links for the PR body. Keep the `media/` branch: deleting it breaks the images once GitHub garbage-collects the commit.

### Before pushing for a PR

Have the change reviewed first, for bugs and for what it could do without:

```bash
hc run --bg reviewer "Review git diff BASE...HEAD in REPO_PATH. WHAT_IT_IS_FOR. Report with hc send $HC_TERMINAL_ID."     # note the address each prints, e.g. t7
hc run --bg simplifier "Review git diff BASE...HEAD in REPO_PATH. WHAT_IT_IS_FOR. Report with hc send $HC_TERMINAL_ID."
hc wait --children all
```

Read their findings files and fix what holds up. Review once; run them again only after a substantial rework. Then `hc kill ADDRESS; hc rm ADDRESS` for each.

### After giving a compare link

Don't stop at the link. From the clone, watch for the PR in the background; `pr-watch` waits up to 2 hours for the user to open it and for its checks to finish, then prints gh's check table once. Its exit wakes you:

```bash
hc run --bg pr-watch OWNER/REPO BRANCH   # note the address it prints, e.g. t7
```

When it exits, `hc read ADDRESS`, then `hc rm ADDRESS`, and tell the user the result. If it stopped on a gh error (network, rate limit), start it again. For a failed GitHub Actions check, the link ends in `/actions/runs/RUN/job/JOB`: read its log with `gh run view -R OWNER/REPO --job JOB --log-failed`, find the cause and propose a fix. Push the fix only to a fork of a `LorenzBischof` repo; for anyone else's repo, show the change and wait for the user to say push.
