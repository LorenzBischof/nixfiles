---
name: nixpkgs-bump-review
description: Use when reviewing a nixpkgs version-bump pull request (usually opened by @r-ryantm / nixpkgs-update) for a package where the user is listed in meta.maintainers. Covers reading the diff, checking upstream changes for anything that breaks the packaging, building and testing the update, and reporting a verdict.
---

# Reviewing a nixpkgs version bump

The user is nixpkgs maintainer **LorenzBischof** (githubId 1837725). Bots open
`pkg: old -> new` PRs against their packages and ping them for testing. This skill is
that review.

Maintainership obliges keeping the package **working and current** — not ownership.
Non-maintainer committers may merge after ~1 week of silence, so the cost of skipping a
review is a merge without you. The duties for a bot PR: read the diff, read upstream,
run the built program, give a verdict.

Find work by searching open nixpkgs PRs that mention `LorenzBischof`. Maintained packages
are wherever `LorenzBischof` appears under `pkgs/` — grep rather than trusting a list.

## 1. The PR, and what CI actually proves

Pull the PR's metadata, diff, checks, and body.

**Do not assume CI built the package.** Nixpkgs CI is GitHub Actions — `Eval/*`, `Lint/*`,
`Check/*`, `Build/*` — and the `Build /` jobs build *shell, docs, lib, tarball*, not your
package. Reading "Build / x86_64-linux ✓" as "the package built" is wrong. Ofborg
(`pkg, pkg.passthru.tests on <system>`) does build it, but it no longer runs on every PR —
it is absent entirely on some bumps. Check whether it is there before relying on it; on
darwin it lags or fails for unrelated reasons, and the merge bot ignores darwin.

On an r-ryantm PR the real build evidence is the **`nixpkgs-review` result pasted in the PR
body** — the bot's build, on the bot's checkout, usually x86_64-linux only. Treat it as
evidence, and say whose build it was in the verdict.

The label `2.status: merge-bot eligible` is CI's verdict on §8. For blast
radius, the Eval Summary's rebuild counts are authoritative — the `10.rebuild-*` labels
count attrs, the body's "N total rebuild path(s)" counts paths from the bot's older
checkout, so they legitimately disagree.

If the PR is **already merged**, review anyway if the user asked: the levers left are a
follow-up fix or, more often, an open `[Backport release-*]` PR carrying the same change
onto a stable branch — see §8.

## 2. The diff should be boring

A clean bump changes *only* `version`, the `src` `hash`/`rev`/`tag`, and one of
`vendorHash` / `cargoHash` / `npmDepsHash`. Anything else is a real change to review.

- **Downgrade**, or a jump onto a major upstream still calls a preview.
- **Pre-release as stable** — `-rc`, `-beta`, `-dev` in the version, *and* GitHub's
  `prerelease` flag on the release, which can be set on a clean-looking version string.
- **`-unstable-` versions** must stay `<last-release>-unstable-YYYY-MM-DD`.
- **Source moved** — a changed `owner`/`repo`/`url`. Verify the new target is the official
  upstream, not a fork or typosquat.
- **A hash changed with no version change**, or `rev` no longer derived from `version` —
  a re-tagged upstream release is a supply-chain smell.
- Commit title must be exactly `pkgname: old -> new`; the prefix is what queues CI builds.

## 3. Read the whole `package.nix`, not just the diff

The diff is three lines. The assumptions live in the ~40 unchanged lines around them, and
the review is checking those against the changed source. So read the file first and list
what it hardcodes about upstream — the fetch target and tag scheme; the dependency hash;
build inputs; which slice of the tree gets built (`subPackages`, `sourceRoot`,
`cargoBuildFlags`, `pyproject`/`build-system`, `makeFlags`); version-stamping build flags
(Go `ldflags -X`, CMake `-DVERSION=`, a `substituteInPlace` writing a version literal); any
`substituteInPlace`/`patches`/`patchShebangs`; wrapper PATH; install paths; the test setup
(`checkFlags`, `doCheck`, `pytestCheckHook`, `disabledTests`, `pythonImportsCheck`); and the
`meta` fields.

The specific attribute names differ per ecosystem; the review question does not. Every item
above is *a claim this derivation makes about upstream's layout*, and the bump is the moment
those claims can quietly stop being true.

**Search-and-replace patching fails in one direction only, which makes it the sharpest
thing to check.** `substituteInPlace` patches paths or strings upstream had *at the old
version*:

- Upstream **removed or renamed** the target → the substitution errors out. Loud, CI
  catches it, fine.
- Upstream **added more instances** — a second file hardcoding a path, a new script with a
  `#!/bin/bash` shebang, another call site of something the package rewrites → the existing
  calls still succeed on the old sites and silently miss the new ones. **Build green, tests
  green, broken at runtime.** Nothing in CI sees this.

So for every path or string the package rewrites, grep the *new* upstream source for other
occurrences. The same asymmetry applies to `patches`: one that no longer applies is loud,
one that still applies to changed code is silent.

## 4. Fetch upstream at both tags — and don't trust the compare view

> **GitHub's compare API and web view truncate at 300 files.** On a busy range they will
> omit files that genuinely changed, with no error — just a short list. Verified: kyverno
> `v1.18.2...v1.19.0` is 270 commits, the compare returns exactly 300 files, and `go.mod`
> and `go.sum` are **not among them** even though `go.sum` did change. Concluding
> "lockfile unchanged" from that lands you straight in the stale-`vendorHash` trap below —
> the failure mode arrived at by following the check meant to prevent it.

So for any file whose change matters — the lockfile (`go.sum`, `Cargo.lock`,
`package-lock.json`, `poetry.lock`), LICENSE, the build definition (`Makefile`,
`CMakeLists.txt`, `pyproject.toml`, `setup.py`), and every source your §3 assumption list
names — **fetch it at both tags and compare directly** rather than asking what the compare
view listed. Use the compare range
for commit messages and a rough sense of scope, not as evidence a file is unchanged.

Release notes are often 300 lines of dependency one-liners with no "breaking changes"
heading. Grep the body for `remov|deprecat|breaking|BREAKING|CVE` rather than reading top
to bottom, then follow the linked PRs that match.

## 5. Check upstream against the assumption list

Note breaking changes and security fixes; the user runs several of these on the homelab
(kyverno, crossplane-cli). But the review question is narrower than "is this release good?"
— it's which of the assumptions from §3 upstream just invalidated:


- **Tag scheme changed** (monorepo `pkg/vX.Y.Z` tags, `v` prefix dropped) → `rev` resolves
  to nothing.
- **Lockfile moved but the diff's dep hash didn't** → `vendorHash` and friends are
  fixed-output derivations addressed *only* by output hash, so Nix substitutes a cached FOD
  matching the **stale** hash instead of rebuilding. "It built" does not prove the vendored
  deps match this version.
- **The target of a version stamp moved** → the stamp silently goes dead. Build-time version
  injection is the same trap in every ecosystem: the flag names a location in upstream's
  source, and **a location that no longer exists is ignored rather than diagnosed**. Go
  `ldflags -X pkg.var=` drops unknown symbols without a word (so a renamed module path or a
  bumped `/vN` suffix empties it); a `substituteInPlace` writing a version literal is loud
  if the pattern vanishes but silent if upstream added a second copy; CMake `-DVERSION=`
  quietly does nothing if the cache variable was renamed. In all of them the build stays
  green and the program reports an empty or stale version.

  A `passthru.tests.version` guards the *one* stamp it asserts on. Any other stamped value —
  build hash, build date, a git describe string — can be dead for releases without anyone
  noticing, so grep the new source for every symbol or variable the derivation names, and
  check §6 that the program prints the new version.
- **Part of the public surface was removed** → nothing in `package.nix` breaks, but the
  user's usage does. A minor bump can delete a subcommand or drop a module export. What
  "surface" means depends on what the package *is*: for a CLI, the registered subcommands
  and their flags; for a library, the exported/public names and the signatures of the ones
  callers reach for; for a service, its config keys and defaults.

  > Clone both tags shallow (`git clone --depth 1 --branch <tag>`) and diff two or three
  > cheap extractions — the file list of the relevant directory, plus a grep for whatever
  > declares a surface entry in this language. Which grep depends on the framework, so look
  > at how the source actually declares things before inventing a pattern: Go CLIs use kong
  > struct tags or cobra `Use:`; Python exposes `__all__`, `def`/`class` at module level, and
  > `project.scripts` in `pyproject.toml`; Rust uses `clap` derives or `pub fn`. Additions
  > are safe — you are looking for the `<` side.
  >
  > Cheaper and language-agnostic where it exists: build both versions and diff their
  > `--help` output, or their installed file lists (`ls -R $out`). That reads the real
  > artifact instead of guessing at source patterns.
  >
  > **A diff of two empty extractions looks exactly like a clean pass.** A grep pattern that
  > matches nothing on *both* tags prints no output, which is the same output as a genuinely
  > unchanged surface — the §4 truncation failure in a new costume. `wc -l` both files and
  > eyeball a few entries before believing the diff; if they are empty, the pattern is wrong,
  > not the surface.
- **Source tree reorganised** → whatever selects the build target points at gone paths:
  `subPackages`, `sourceRoot`, `cargoBuildFlags`, a `pyproject.toml` moved into a subdir, a
  renamed `src/` layout. Worst case it **silently builds nothing** and still installs an
  output, so check the output actually contains what it should (§6).
- **New native dependency or codegen tool** → missing `buildInputs`. Required ones fail at
  compile time; *optional* ones build fine and fail at runtime.
- **Build system migrated** (Makefile → CMake/meson) → hooks arrive through
  `nativeBuildInputs` and rewrite the phases wholesale; the whole derivation is wrong.
- **Build now fetches or generates over the network** → fails in the Nix sandbox.
- **Tests now need network, a daemon, or a container** → `checkPhase`, `passthru.tests`.
- **New hardcoded path or new script** → silently unpatched, per the asymmetry in §3.
- **Upstream shells out to a new external tool** → needs adding to the wrapper PATH.
  Nothing catches this at build time.
- **Output layout moved** — binary renamed, completions or man pages relocated →
  `meta.mainProgram`, wrappers, `installShellCompletion`.
- **Toolchain minimum raised** → vs. whatever compiler nixpkgs pins for this package.
- **Platform support dropped or added** → `meta.platforms`.
- **License changed at the new tag** → `meta.license` must match upstream's LICENSE *there*,
  not at the old version.
- **Releases moved repo or went independently versioned** → `meta.changelog` 404s.

  > Real example, PR #556556: `crossplane-cli` fetches `crossplane/cli` but points
  > `meta.changelog` at `crossplane/crossplane` releases. The CLI now versions independently
  > — `crossplane/crossplane`'s newest tags are `v2.4.0` and `v2.5.0-rc.0` — so after the
  > 2.5.0 bump that URL 404s. Package builds, binary runs, CI green, metadata wrong.
  >
  > **Check the old version's URL too before calling it a finding.** Here `v2.4.1` 404s
  > as well, so the bump exposes a pre-existing bug rather than introducing one — which
  > moves it from a reason to hesitate to a footnote plus a separate one-line PR. Same test
  > for any `meta` wart: resolve it at *both* versions, and report which one broke it.

- **Release cadence or tagging changed** → the bot keeps picking wrong versions. Fix the
  cause in `passthru.updateScript` (a version regex, `passthru.skipBulkUpdate = true;`, or
  `# nixpkgs-update: no auto update`), or the next run repeats it.

An upstream API break also breaks *dependent* packages even when this one builds — the
rebuild counts from §1 say how many.

## 6. Build and run it

```bash
cd ~/git/github.com/NixOS/nixpkgs && nix run nixpkgs#nixpkgs-review -- pr <PR>
```

Not installed on this system, hence `nix run`. It builds the PR and everything that
rebuilds because of it, reuses ofborg's evaluation, and drops you in a shell with the
results on `$PATH`. Avoid its `approve`, `merge`, and `--post-result` subcommands — they
write to the PR, which this token cannot do (§7).

> **It must run from inside a nixpkgs checkout**, and there is usually not one on this
> machine. `find_nixpkgs_root()` walks up from CWD for `nixos/release.nix` (or accepts a
> bare repo); with neither it exits `Has to be executed from nixpkgs repository` — **after**
> `nix run` has spent a minute downloading nixpkgs-review itself, so it reads like a slow
> build rather than an instant argument error. No flag bypasses it. Clone once, blobless to
> keep it small, and reuse it for every later review:
>
> ```bash
> git clone --filter=blob:none https://github.com/NixOS/nixpkgs ~/git/github.com/NixOS/nixpkgs
> ```

**Fallback when there's no checkout and the rebuild count is 1–2** (from the §1 Eval
Summary): build the bot's exact commit straight from the PR body, which needs no clone and
covers the same ground, since with one rebuild there are no dependents for nixpkgs-review
to add. Build `passthru.tests` explicitly — nothing else pulls them in.

```bash
nix build --no-link --print-out-paths \
  'github:r-ryantm/nixpkgs/<commit>#<pkg>' \
  'github:r-ryantm/nixpkgs/<commit>#<pkg>.passthru.tests.<name>'
```

Name each `passthru.tests` attribute explicitly — nothing else pulls them in.

Say in the verdict which of the two you ran. Two things in that build log are evidence in
their own right, so read it rather than just checking the exit code:

- **The dependency FOD built instead of being substituted** — the vendor derivation
  appearing under `building '...'` rather than `copying path`. It is named for the fetcher:
  `-go-modules` (buildGoModule), `-vendor` / `-cargo-deps` (Rust), `-npm-deps`, `-composer-vendor`,
  or the `fetchPnpmDeps`/`fetchYarnDeps` output. This is the one thing that actually refutes
  §5's stale-hash trap: a substituted FOD proves only that *some* cached path matches the
  declared hash, while one built from scratch proves the declared hash matches the deps
  *this source* resolves to. (Packages with no vendored-dep FOD — most Python ones, which
  take their deps from nixpkgs rather than a lockfile — are simply not exposed to that trap.)
- **The output path equals the one in the PR body** (`found <version> with grep in
  /nix/store/...`) — same hash means your build reproduced the bot's exactly.

**Then exercise the output — a green build does not cover it.** The dead-version-stamp
failure from §5 shows up here and nowhere else, so start by making the package state its own
version and confirm it is the *new* one, not empty and not the old one. How you do that
depends on the package:

- **A program** — run `$out/bin/<mainProgram> --version` (or `version`, `-V`), then the
  subcommand or flag §5 flagged as changed, then its primary path.
- **A library** — there is no binary, so import it and run the test suite:
  `nix build ...#<pkg>` then check `pythonImportsCheck`/`doCheck` actually ran in the log
  rather than being skipped, and for a Python bump confirm the new version does not violate
  a dependent's upper bound.
- **A service** — start it if it is cheap to, otherwise lean on `passthru.tests` and any
  NixOS VM test that references it.

Also confirm the output is not *empty of the thing it should contain* — `ls -R $out` catches
the silently-built-nothing case from §5. The user's own usage of these packages is not
visible in the nixfiles repo, so if a change looks like it might affect how they run it, ask
rather than guess. `nixpkgs-review` builds `passthru.tests` too — worth noting in the
verdict either way.

## 7. Report the verdict — post nothing

The GitHub token here has **no approve or comment permissions**. Never issue a write call
against the PR; posting under the user's account is their step.

Finish with a few lines saying what you'd do:

> **#556556 crossplane-cli: 2.4.1 → 2.5.0 — would approve.**
> Version-only diff, no downgrade or pre-release. Upstream is dep bumps plus
> `render`/`projects` fixes, no breaking changes; license unchanged (Apache-2.0).
> Built the bot's commit locally (x86_64-linux, no nixpkgs checkout for nixpkgs-review);
> vendor FOD rebuilt from scratch and the output path matches the bot's.
> `crossplane version --client` prints v2.5.0; `passthru.tests.version` passes.
> ofborg green on x86_64/aarch64-linux, darwin pending. Note: `meta.changelog` 404s at
> both 2.4.1 and 2.5.0 — pre-existing, separate fix.

That example is a Go CLI; the *shape* is what carries over. Whatever the ecosystem, the
verdict should state: the verdict itself, whether the diff was version-only, what upstream
changed that bears on the packaging, how the dependency hash was verified (or that the
package has no vendored-dep FOD), which build you ran and on what system, what you got when
you exercised the output, the CI position, and any finding you are explicitly setting aside.

Or `would request changes`, with the reason and what would need to happen first. Only claim
checks you actually ran; if you skipped the build, say so rather than implying a clean
review. If the user wants it posted, hand them the commands to run themselves.

## 8. Merge-bot eligibility

Worth a line in the verdict. The user is a maintainer, not a committer, so commenting
`@NixOS/nixpkgs-merge-bot merge` is the only lever. It merges only if **all** hold: the PR
targets a development branch (`master`, `staging-*`, `release-*`); touches **only**
`pkgs/by-name/*`; was opened by @r-ryantm or a committer (or approved by one); the commenter
is in @NixOS/nixpkgs-maintainers **and maintains every package touched**; and no committer
has an outstanding "changes requested" review.

Green CI → merge queue. CI pending → Auto Merge is enabled and it lands later unattended, so
a merge comment then is a decision to merge sight-unseen. CI already failing → the bot does
nothing and the command must be repeated after a fix.

Packages outside `pkgs/by-name` (the `pkgs/development/python-modules/*` ones) are not
eligible; an approval there just waits for a committer.


### Backports

A `backport release-*` label auto-opens a second PR carrying the same change onto a stable
branch, and it often outlives the master PR — merge-bot eligible, unreviewed, and unnoticed
because the original already merged. **Always check whether one is open**, and review it as
a separate decision rather than assuming the master verdict carries over.

The bar there is different: stable branches take bugfixes and security updates, and a bump
that is fine on master can be wrong on `release-*` if it removes a subcommand, changes
defaults, or carries anything users on a stable channel wouldn't expect mid-release. That
judgement is the maintainer's and nobody else will make it.
## Sources

- [`pkgs/README.md#reviewing-contributions`](https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md#reviewing-contributions) — official review checklist for package updates, plus versioning, `meta` and commit conventions.
- [`maintainers/README.md`](https://github.com/NixOS/nixpkgs/blob/master/maintainers/README.md) — what maintainership obliges.
- [`ci/README.md#merge-bot-constraints`](https://github.com/NixOS/nixpkgs/blob/master/ci/README.md#merge-bot-constraints) — exact merge-bot preconditions.
- [nixpkgs-update maintainer FAQ](https://nix-community.github.io/nixpkgs-update/nixpkgs-maintainer-faq/) — the duties for a bot PR.
- [Nixpkgs/Automatic Updates](https://wiki.nixos.org/wiki/Nixpkgs/Automatic_Updates) — how r-ryantm picks versions and its failure modes.
- [nixpkgs-review README](https://github.com/Mic92/nixpkgs-review) — flags and subcommands.
