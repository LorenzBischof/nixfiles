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
- Only warnings that are actionable here matter: ones where something in this repo
  has to change, now or before a stated removal. A warning from inside an input,
  or one nothing here can act on, is noise — leave it out of the comment entirely
  rather than explaining why it's harmless. `stdenv.isDarwin is deprecated` is the
  standing example; note it only if it starts failing something.

## Working style

This is a one-shot CI job: it ends the moment you stop, so anything still running
is killed and its output is lost. Never start a subagent in the background, and
never finish your turn with one still outstanding — if you delegate, wait for the
result. Read the logs, push any fix, and leave the comment before you finish.

Every claim in the comment about where something comes from — which input, which
file, which package — rests on a path you actually read. Where you couldn't
establish it, say that instead of offering a guess as a finding.

## Progress comment

Keep a single sticky PR comment current as you work, using
`gh pr comment --edit-last --create-if-none --body '...'`. Always leave one, even
when nothing is wrong — the comment is the only evidence this job ran at all, so
its absence has to mean the job is broken rather than that the bump was clean.

Write it terse: no headings, no preamble, no restating the task or narrating how
you looked into it — just the findings, in plain sentences. Nothing to report is a
single line naming what you checked, so the all-clear is evidence rather than an
assertion: "All four targets built, logs clean, version diff routine (homeassistant
2026.9.1 → 2026.9.2 on nas)."

Something worth raising — a build failure, an actionable deprecation, a risky
version bump — replaces that line with a line or two each: what breaks and what it
needs. Leave out anything that needs no action from us. If a previous run reported
an issue that is now resolved, say so in a clause.

Don't name internal files, paths or job steps in the comment — the reader only sees
the PR. Call the application diff "the version diff", and refer to logs by target
name rather than by path.

## Build failures

If a target failed, the cause is a change in an upstream input (usually nixpkgs).
Find the root cause from the failed log and look only at the files, derivation
logs (`nix log <drv>`), or upstream `-source` paths the error points to. Use
`gh search issues` / `gh search prs` against nixpkgs and the implicated upstream
flake input's repo — the fix or an explanation often lives there.

## Deprecations

For each deprecation warning, identify what triggers it and what the replacement
is. Search upstream as above when the message isn't self-explanatory. If it turns
out to be purely upstream, or otherwise needs nothing from this repo, drop it —
don't spend a line of the comment on it.

Tip: to locate an `evaluation warning:`, turn it into a traceable abort with
`nix eval --option abort-on-warn true --show-trace
.#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`. The trace ends
on the source line that caused it, usually inside a flake input. It stops at the
first warning.

### Never guess which input a warning comes from

Naming the wrong input is worse than naming none — it sends the reader to fix a
repo that has nothing to do with it. A module path like `modules/rofi/hm.nix`
identifies nothing on its own: many inputs have a `modules/` tree, and plain text
search is treacherous (grepping `rofi` matches every `profile`). So an input is
only ever named on the strength of a store path.

Get the store path from the warning itself or from the abort-on-warn trace above,
then map it to the input that owns it:

```
nix eval --impure --json --expr \
  'let f = builtins.getFlake (toString ./.); in builtins.mapAttrs (n: i: i.outPath or null) f.inputs'
```

The `/nix/store/<hash>-source` prefix in the trace matches exactly one entry;
that entry is the owning input, whatever the file inside it happens to be called.
Confirm by reading the file at that path and seeing the option actually set there.

If no store path is available, say only what you know — which option is renamed,
that nothing in this repo sets it, and that you could not pin down the input.
Never fill the gap with a plausible-sounding input name.

## Application version bumps

The repo root holds `pkgdiff.txt` — a unified diff, per host, of the applications
each config names and their versions: enabled services, system packages, and
home-manager packages. Libraries and other transitive dependencies are
deliberately absent, as are packages with no version attribute, so every line is
something this repo actually runs. A bump reads as a `-`/`+` pair on the same name.
The file is missing or empty when nothing moved, or when the diff could not be
computed.

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
