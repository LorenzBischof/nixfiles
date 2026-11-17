---
name: nixpkgs-review-gha
description: Use when a nixpkgs pull request needs nixpkgs-review run on it — building every package the PR changes or rebuilds, on Linux and Darwin — whether it is a version bump, a fix, a new package or a refactor. Runs remotely in GitHub Actions through the user's nixpkgs-review-gha fork and posts the report on the PR; no local nixpkgs checkout or local build needed.
---

# nixpkgs-review in GitHub Actions

The user's fork `LorenzBischof/nixpkgs-review-gha` runs `nixpkgs-review pr <n>` on
x86_64-linux, aarch64-linux, x86_64-darwin and aarch64-darwin, and collects the
results in one report. The `gh` token can dispatch it (Actions: write on the fork).

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
| `pending-eval` | no `10.rebuild-*` labels: CI eval not finished or failed | `--force` |
| `running` | run in flight, linked | none |
| `no-rebuilds` | 0 rebuilds on Linux and Darwin | none |
| `closed` | merged or closed | none |

Tags `[draft]` and `[mass-rebuild linux:2501-5000]` (501+ rebuilds, more than the runners
are meant for) also need `--force`. Dispatching skips what needs `--force` unless given;
pass it only once the user has said so. If a run failed before posting, find out why
before retrying.

## Follow it

```bash
gh run list -R LorenzBischof/nixpkgs-review-gha -w review.yml -L 3   # find the run id
gh run watch <id> -R LorenzBischof/nixpkgs-review-gha --exit-status
```

A small PR takes a few minutes; Darwin is usually last. Each `review (<system>)` job is
one platform, and `report` posts the comment once all are done.

## Read the result

Read the comment back from the PR. For a pass/fail overview, the platform headings and
result summaries are enough; read the full body only for the packages that failed:

```bash
gh api --paginate 'repos/NixOS/nixpkgs/issues/<number>/comments?per_page=100' \
  --jq '.[] | select(.user.login=="nixpkgs-review-gha") | .html_url, .body' \
  | grep -E '^https://|^### |<summary>'
```

Without `--post-result`, the report only exists as run artifacts (`report.md`, `report_<system>.json`).
`gh run download` fetches them from Azure blob storage, which the sandbox does not reach;
fall back to the job logs:

```bash
gh run view <id> -R LorenzBischof/nixpkgs-review-gha --log --job <job-id>
```

The report lists, per platform, packages built, failed to build, and skipped as
broken/unsupported. A failure on Darwin alone, or a NixOS test failing for lack of `kvm`,
is often not the PR's fault — check the failed package on the base branch before
blaming the change. To debug a failure locally, there is a nixpkgs checkout at
`~/git/github.com/lorenzbischof/nixpkgs` (jj, remotes `origin` = NixOS, `fork` =
the user's fork).
