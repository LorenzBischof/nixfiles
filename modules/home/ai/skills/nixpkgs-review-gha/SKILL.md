---
name: nixpkgs-review-gha
description: Use when a nixpkgs pull request needs nixpkgs-review run on it — building every package the PR changes or rebuilds, on Linux and Darwin — whether it is a version bump, a fix, a new package or a refactor. Runs remotely in GitHub Actions through the user's nixpkgs-review-gha fork and posts the report on the PR; no local nixpkgs checkout or local build needed.
---

# nixpkgs-review in GitHub Actions

The user's fork `LorenzBischof/nixpkgs-review-gha` runs `nixpkgs-review pr <n>` on
Linux and Darwin and collects the results in one report. The `gh` token can dispatch it
(Actions: write on the fork).

Only for NixOS/nixpkgs pull requests — nixpkgs-review cannot build anything else.

## Find and start runs

```bash
nixpkgs-review-gha                       # list the queue, dispatch nothing
nixpkgs-review-gha --post-result <pr>... # dispatch
```

The queue is every open PR involving the user (`--involves @me`): authored, review
requested, mentioned, assigned or commented on. That is broader than what needs a run, so
judge each line; PRs outside it take their number explicitly.

Dispatching takes a subset of `nixpkgs-review pr`'s flags (`--post-result`, `--systems`,
`--tests`, `-p`, `-P`) plus `--force`. `--systems` defaults to the platforms whose
`10.rebuild-*` label is not 0. Leave out `--post-result` only for a throwaway run; the
report is posted by `@nixpkgs-review-gha` and names the user as the one who triggered it.

Both modes print one line per PR: `#<pr> [tags] <state>: <title>; <detail>; <next step>`.

| State | Meaning | Next step |
|---|---|---|
| `missing` | never reviewed | run |
| `outdated` | reviewed, but pushed since; links the old report | run |
| `current` | report for this head, linked — pass or fail, read it | `--force` |
| `pending-eval` | no `10.rebuild-*` labels: CI's eval not finished, failed or cancelled | wait, or re-run CI's eval |
| `running` | run in flight, linked | none |
| `no-rebuilds` | 0 rebuilds on Linux and Darwin | none |
| `closed` | merged or closed | none |

Tags `[draft]` and `[mass-rebuild linux:2501-5000]` (501+ rebuilds, more than the runners
are meant for) also need `--force`. Dispatching skips what needs `--force` unless given;
pass it only once the user has said so.

## Follow it

```bash
gh run list -R LorenzBischof/nixpkgs-review-gha -w review.yml -L 3   # find the run id
gh run watch <id> -R LorenzBischof/nixpkgs-review-gha --exit-status --interval 60 >/dev/null
echo "exit=$?"
gh run view <id> -R LorenzBischof/nixpkgs-review-gha --json jobs --jq '.jobs[] | "\(.name) \(.conclusion)"'
```

Run it in the background and wait for the notification.

A small PR takes a few minutes; Darwin is usually last. Each `review (<system>)` job is
one platform.

## When a run fails

When `gh run watch` exits non-zero, find out why before dispatching again. The failed
jobs' annotations give the reason through the API, with no log download:

```bash
gh run view <id> -R LorenzBischof/nixpkgs-review-gha --json jobs \
  --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled") | "\(.databaseId) \(.name)"'
gh api repos/LorenzBischof/nixpkgs-review-gha/check-runs/<job-id>/annotations --jq '.[].message'
```

The `report` job needs every `review` job, so one cancelled platform means no report is
posted, even for the platforms that passed. Upstream tracks this as
Defelo/nixpkgs-review-gha#233.

| Annotation | Cause | Do, without asking |
|---|---|---|
| `review (*-darwin)`: "not acquired by Runner … after multiple attempts" | no macOS runner free within 15 minutes | dispatch again with Linux only, `--post-result --systems "x86_64-linux aarch64-linux" <pr>`, and tell the user Darwin was left out. Don't chase Darwin afterwards; the next push's run covers it |
| `report`: "Network unreachable" on `nrgha-api.defelo.de` | the upstream report API is down | `gh run rerun <id> --failed` reruns `report` alone, with no rebuilds. Once; if it fails again, stop and tell the user |

Anything else, read the job log and tell the user rather than retrying.

## Read the result

Read the comment back from the PR. For a pass/fail overview, the platform headings and
result summaries are enough; read the full body only for the packages that failed:

```bash
gh api --paginate 'repos/NixOS/nixpkgs/issues/<number>/comments?per_page=100' \
  --jq '.[] | select(.user.login=="nixpkgs-review-gha") | .html_url, .body' \
  | grep -E '^https://|^### |<summary>'
```

Without `--post-result`, the report only exists as run artifacts (`report.md`, `report_<system>.json`).
`gh run download` fetches them from Azure blob storage, which the sandbox does not reach.
Fall back to the job logs. They need a writable gh cache and the
`results-receiver.actions.githubusercontent.com` host:

```bash
XDG_CACHE_HOME=$TMPDIR/gh gh run view <id> -R LorenzBischof/nixpkgs-review-gha --log --job <job-id>
```

The report lists, per platform, packages built, failed to build, and skipped as
broken/unsupported. A failure on Darwin alone, or a NixOS test failing for lack of `kvm`,
is often not the PR's fault — check the failed package on the base branch before
blaming the change. To debug a failure locally, there is a nixpkgs checkout at
`~/git/github.com/lorenzbischof/nixpkgs` (jj, remotes `origin` = NixOS, `fork` =
the user's fork).
