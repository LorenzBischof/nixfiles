A Dependabot PR that only bumps `flake.lock` triggered a CI run. This job runs on
every Dependabot bump now — whether the build passed or failed — to (1) diagnose
and, where safe, fix any build failure, (2) flag deprecation warnings the upstream
input bump introduced, and (3) flag application version bumps that look like they
carry breaking changes.

Build/eval logs for every matrix target are in
`build-logs/build-log-<target>/build.log` (targets: `flake-check`, `framework`,
`nas`, `vps`). Start by reading them to establish the state of each target:

- A log ending in an `error:` means that target failed to build.
- Logs that built cleanly may still contain `warning:` / `evaluation warning:`
  lines — these are the deprecations to look for (renamed/removed options, modules
  scheduled for removal, `lib.warn`/`trace` notices from the bumped inputs).
- One warning is long-standing rather than new: `stdenv.isDarwin is deprecated`
  comes from inside an input and is not actionable here. Don't re-litigate it
  every run; note it only if it starts failing something.

## Working style

This is a one-shot CI job: it ends the moment you stop, so anything still running
is killed and its output is lost. Never start a subagent in the background, and
never finish your turn with one still outstanding — if you delegate, wait for the
result. Read the logs, push any fix, and leave the comment before you finish.

## Progress comment

Keep a single sticky PR comment current as you work, using
`gh pr comment --edit-last --create-if-none --body '...'`. Always leave one, even
when nothing is wrong — the comment is the only evidence this job ran at all, so
its absence has to mean the job is broken rather than that the bump was clean.

When there is nothing to report, keep it to a single line, and name what you
actually checked so the all-clear is evidence rather than an assertion — which
targets built, that you read their logs for deprecation warnings, and that you
read the version diff. For example: "All four targets built; no deprecation
warnings in the logs; version diff is routine (homeassistant 2026.9.1 → 2026.9.2
on nas)."

Anything worth raising — a build failure, a deprecation, a risky version bump —
replaces that line with the detail. If a previous run reported an issue that is
now resolved, say so explicitly instead of quietly dropping it.

## Build failures

If a target failed, the cause is a change in an upstream input (usually nixpkgs).
Find the root cause from the failed log and look only at the files, derivation
logs (`nix log <drv>`), or upstream `-source` paths the error points to. Use
`gh search issues` / `gh search prs` against nixpkgs and the implicated upstream
flake input's repo — the fix or an explanation often lives there.

## Deprecations

For each deprecation warning, identify what triggers it (which option/module in
this repo, or whether it's purely upstream and not actionable here) and what the
replacement is. Search upstream as above when the message isn't self-explanatory.

Tip: to locate an `evaluation warning:`, turn it into a traceable abort with
`nix eval --option abort-on-warn true --show-trace
.#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`. The trace ends
on the source line that caused it, usually inside a flake input. It stops at the
first warning.

## Application version bumps

`pkgdiff.txt` holds a unified diff, per host, of the applications each config
names and their versions — enabled services, system packages, and home-manager
packages. Libraries and other transitive dependencies are deliberately absent,
as are packages with no version attribute, so every line is something this repo
actually runs. A bump reads as a `-`/`+` pair on the same name. The file is
missing or empty when nothing moved, or when the diff could not be computed.

Do not report the whole list — most of it is routine. Pick out the bumps that
plausibly break something and check them:

- Anything crossing a major version, and anything for a service holding state
  that an upgrade migrates in place (databases, Grafana, Home Assistant,
  Vaultwarden, the \*arr services). A one-way database migration landing via
  auto-merge is the case worth catching.
- Read the upstream release notes for the versions crossed — `gh release view
  --repo <owner>/<repo> <tag>`, or `gh api` for the release list. The NixOS
  release notes matter too when a module changed alongside the package.
- Say what would break and what it needs, rather than just that a version moved.
  If it needs a config change here, treat it like any other fix below. If it
  needs manual action on a host (a backup before migration, a state format
  change), do not push anything — describe it in the comment.

Nothing worth flagging is the normal outcome; the one-line all-clear above covers
that case.

## Fixing

For both failures and clearly-safe deprecations: if the fix is small and clearly
correct (a renamed or removed option, a changed module interface), edit the files,
verify, then commit and push to this PR branch:
`git add -A && git commit -m '...' && git push origin HEAD`.

You decide what verification the fix actually needs. For an eval-time issue (an
assertion, a removed/renamed option, a changed module interface) evaluating the
affected host configs is usually enough; a full build is only worth it when the
break is in the build itself. Check whichever host configs the change could
affect — for example, to evaluate vs. to fully build the `framework` config:

```
nix eval .#nixosConfigurations.framework.config.system.build.toplevel.drvPath
nix build .#nixosConfigurations.framework.config.system.build.toplevel
```

If a fix is non-trivial, uncertain, or an upstream bug to wait out, don't edit or
push anything — just describe it in the comment.

Either way, say in the comment whether you pushed a fix and what it was, or that
you left it for a human.
