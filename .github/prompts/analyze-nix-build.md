A Dependabot PR that only bumps `flake.lock` triggered a CI run. This job runs on
every Dependabot bump now — whether the build passed or failed — to (1) diagnose
and, where safe, fix any build failure, and (2) flag deprecation warnings the
upstream input bump introduced.

Build/eval logs for every matrix target are in
`build-logs/build-log-<target>/build.log` (targets: `flake-check`, `framework`,
`nas`, `vps`). Start by reading them to establish the state of each target:

- A log ending in an `error:` means that target failed to build.
- Logs that built cleanly may still contain `warning:` / `evaluation warning:`
  lines — these are the deprecations to look for (renamed/removed options, modules
  scheduled for removal, `lib.warn`/`trace` notices from the bumped inputs).

## Progress comment

Keep a single sticky PR comment current as you work, using
`gh pr comment --edit-last --create-if-none --body '...'`. But only do so if there
is something to report — a build failure or a deprecation. If every target built
cleanly with no deprecation warnings, do NOT create a comment; and if a stale
comment from a previous run exists, edit it to note the issue is resolved.

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

Either way, leave your sticky comment self-contained: say whether you pushed a fix
(and what it was) or left it for a human, covering both the failure (if any) and
any deprecations, in clear prose with no rigid template.
