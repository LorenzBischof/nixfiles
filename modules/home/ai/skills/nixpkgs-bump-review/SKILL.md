---
name: nixpkgs-bump-review
description: Use when reviewing a nixpkgs version-bump pull request (usually opened by @r-ryantm / nixpkgs-update) for a package where the user is listed in meta.maintainers. Covers reading the diff, checking upstream changes for anything that breaks the packaging, building and testing the update, and reporting a verdict.
---

# Reviewing a nixpkgs version bump

Bots open `pkg: old -> new` PRs against packages the user maintains and ping them for
testing. This skill is that review.

Maintainership obliges keeping the package **working and current** — not ownership. The FAQ's
duties for a bot PR: review the diff, review upstream changelogs and commits, follow the PR's
test instructions, then approve or request changes.

Find the work:

```bash
gh search prs --repo NixOS/nixpkgs --state open --involves @me --json number,title,updatedAt
```

`--involves`, not `--mentions`: a `[Backport release-*]` PR carries no maintainer ping (§8).

## 1. The PR, and what CI actually proves

```bash
gh pr view <PR> --repo NixOS/nixpkgs --json title,body,labels,state,mergedAt
gh pr diff <PR> --repo NixOS/nixpkgs
gh pr checks <PR> --repo NixOS/nixpkgs
```

**Do not assume CI built the package.** The `Build /` jobs build *shell, docs, lib, tarball*
— not your package — so a green `Build / x86_64-linux` says nothing about this bump. Ofborg
(`pkg, pkg.passthru.tests on <system>`) does build it, but no longer runs on every PR and is
absent entirely on some bumps, so check whether it is there at all before relying on it.

The real build evidence is in the PR body: the **`nixpkgs-review` result** (the bot's build,
usually x86_64-linux only — say whose build it was in the verdict), the **Checks done** list,
whose `found <version> with grep in /nix/store/...` names the bot's output path, and the
collapsed **Instructions to test this update**, which is where §6 gets its commands.

The label `2.status: merge-bot eligible` is CI's verdict on §8. For blast radius use the Eval
Summary's rebuild counts, not the body's "N total rebuild path(s)".

If the PR is **already merged**, review anyway if the user asked: the levers left are a
follow-up fix or, more often, an open `[Backport release-*]` PR carrying the same change onto
a stable branch — see §8.

## 2. The diff should be boring

A clean bump changes *only* `version`, the `src` `hash`/`rev`/`tag`, and one of
`vendorHash` / `cargoHash` / `npmDepsHash`. Anything else is a real change to review.

- **Downgrade**, or a jump onto a major upstream still calls a preview.
- **Pre-release as stable** — `-rc`, `-beta`, `-dev` in the version, *and* GitHub's
  `prerelease` flag on the release, which can be set on a clean-looking version string.
- **`-unstable-` versions** must stay `<last-release>-unstable-YYYY-MM-DD`, or
  `0-unstable-YYYY-MM-DD` where upstream has no suitable preceding release.
- **Source moved** — a changed `owner`/`repo`/`url`. Verify the new target is the official
  upstream, not a fork or typosquat.
- **A hash changed with no version change**, or `rev` no longer derived from `version` —
  a re-tagged upstream release is a supply-chain smell.
- Commit title must be exactly `pkgname: old -> new`; the prefix is what queues CI builds.

## 3. Read the whole `package.nix`, not just the diff

The diff is three lines; the assumptions live in the ~40 unchanged lines around them, and
the review is checking those against the changed source. So read the file first and list what
it hardcodes about upstream: the fetch target and tag scheme, the dependency hash, build
inputs, which slice of the tree gets built, any version-stamping build flag, every
`substituteInPlace`/`patches`/`patchShebangs`, the wrapper PATH, install paths, the test
setup, and the `meta` fields.

Each is a claim about upstream's layout that a bump can quietly falsify. Attribute names
differ per ecosystem; the question does not. If you cannot tell why one is there (a pin,
a `disabledTests`, an opinionated patch), you cannot tell whether it still applies at the new
version; say so rather than assuming.

**Search-and-replace patching fails in one direction only.** `substituteInPlace` patches
paths or strings upstream had *at the old version*:

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

> **GitHub's compare API and web view truncate at 300 files.** On a range of a few hundred
> commits they omit files that genuinely changed, with no error — just a short list, which can
> leave out the lockfile when the lockfile did change. Concluding "lockfile unchanged" from
> that lands you in the stale-`vendorHash` trap in §5.

So for any file whose change matters — the lockfile (`go.sum`, `Cargo.lock`,
`package-lock.json`, `poetry.lock`), LICENSE, the build definition (`Makefile`,
`CMakeLists.txt`, `pyproject.toml`, `setup.py`), and every source your §3 assumption list
names — **fetch it at both tags and compare directly** rather than asking what the compare
view listed. Use the compare range for commit messages and a rough sense of scope, not as
evidence a file is unchanged.

Release notes are often 300 lines of dependency one-liners with no "breaking changes"
heading. Grep the body for `remov|deprecat|breaking|BREAKING|CVE` rather than reading top
to bottom, then follow the linked PRs that match.

## 5. What the bump can quietly invalidate

Note breaking changes and security fixes, the more so for a package the user actually runs.
But the review question is narrower than "is this release good?" — which of §3's assumptions
did upstream just invalidate?

Most ways a bump breaks a package are **loud**: a migrated build system, a raised toolchain
minimum, a build that now needs the network, tests that now need a daemon, a required new
dependency, a `rev` that no longer resolves. Those fail in §6's build. The review is for the
failures that leave it green:

- **A stale dependency hash.** The lockfile moved and the diff's `vendorHash` didn't. These
  are fixed-output derivations addressed *only* by their output hash, so Nix substitutes a
  cached FOD matching the **stale** hash instead of rebuilding. "It built" does not prove the
  vendored deps match this version; §6 route B is what refutes it.
- **A dead version stamp.** Version injection names a *location* in upstream's source, and a
  location that no longer exists is ignored rather than diagnosed: Go `ldflags -X pkg.var=`
  drops unknown symbols silently, so a renamed module path or a bumped `/vN` suffix empties
  it; CMake `-DVERSION=` does nothing if the cache variable was renamed. The build stays green
  and the program reports an empty or stale version. `passthru.tests.version` guards only the
  stamp it asserts on, so grep the new source for every symbol the derivation names, and
  confirm in §6 that the program prints the new version.
- **An unpatched new instance**, per §3's asymmetry: upstream added another hardcoded path,
  another shebang, another call site, and the existing `substituteInPlace` still succeeds on
  the old ones.
- **A new external tool.** Upstream shells out to something it did not before; it needs
  adding to the wrapper PATH, and nothing catches that at build time.
- **A build target that selects nothing.** Upstream reorganised the tree and `subPackages`,
  `sourceRoot` or `cargoBuildFlags` point at paths that are gone. Worst case the derivation
  installs an output with nothing in it, which is why §6 ends on `ls -R`.
- **`meta` drift.** The license can change at a new tag — upstream's checklist calls this out
  specifically — so check `meta.license` against the LICENSE file *there*, not at the old
  version. `meta.changelog` 404s when releases move repo or go independently versioned.

  > **Resolve a `meta` URL at both versions before calling it a finding.** A `meta.changelog`
  > that 404s at the new version usually 404s at the old one too — a package fetching one repo
  > but pointing its changelog at another that has since versioned independently, say. That
  > makes it a pre-existing bug: a footnote plus a separate one-line PR, not a reason to
  > hesitate.

If the bot picked the wrong version at all — a changed tagging scheme or release cadence —
fix the cause in `passthru.updateScript` (a version regex, `passthru.skipBulkUpdate = true;`,
or `# nixpkgs-update: no auto update`), or the next run repeats it. The FAQ lists the full set
of reasons the bot skips or mis-picks a package.

An upstream API break also breaks *dependent* packages even when this one builds — §1's
rebuild counts say how many.

## 6. Get the build, and exercise it

The PR body's **"Instructions to test this update"** carries the bot's store path and its
commit — lift them from there rather than reconstructing. Three routes to *get* the build,
proving different things; exercising it happens in the VM at the end of this section.

### A. Download the bot's build from the cache

```bash
nix-store -r /nix/store/<path-from-the-PR-body> \
  --option binary-caches 'https://cache.nixos.org/ https://nixpkgs-update-cache.nix-community.org/' \
  --option trusted-public-keys '
  nixpkgs-update-cache.nix-community.org-1:U8d6wiQecHUPJFSqHN9GSSmNkmdiFW7GW7WNAnHW0SM=
  cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
  '
```

Run it with the sandbox disabled. No clone and no compile, just the download.

Usually enough: it gets you the real artifact to run, which is what the FAQ's test duty asks
for and what CI never covers, and on a routine patch bump running the program *is* the review.
It re-derives no hash though — you asked for a store path by name and got the bot's bytes
back, so "the output path matches" is tautological here. If the bump touched a lockfile, use
route B.

### B. Build the bot's commit yourself

```bash
nix build --no-link --print-out-paths \
  'github:r-ryantm/nixpkgs/<commit>#<pkg>' \
  'github:r-ryantm/nixpkgs/<commit>#<pkg>.passthru.tests.<name>'
```

Name each `passthru.tests` attribute explicitly — nothing else pulls them in. Needs no clone,
and it hands you the output too, so this subsumes route A. Two things in the log are evidence
in themselves:

- **The dependency FOD built instead of being substituted** — the vendor derivation under
  `building '...'` rather than `copying path` (`-go-modules` for buildGoModule,
  `-vendor`/`-cargo-deps` for Rust, `-npm-deps`). This is what refutes §5's stale-hash trap:
  a substituted FOD proves only that *some* cached path matches the declared hash, while one
  built from scratch proves the hash matches the deps *this source* resolves to. A package
  whose deps come from nixpkgs rather than a lockfile has no such FOD and is not exposed.
- **The output path equals the one in the PR body** (`found <version> with grep in
  /nix/store/...`) — same hash means your build reproduced the bot's exactly.

### C. nixpkgs-review — only if dependents matter

It adds the one thing route B cannot: everything that rebuilds *because* of this change.
Worth having when the §1 rebuild count is large, worth nothing when it is 1.

It only runs from inside a nixpkgs checkout, and there is none on this machine. Cloning
nixpkgs is a decision to put to the user, not a step to take mid-review.

### Then exercise the output — in the agent VM

The output never runs on this machine. Every call into it goes through the agent VM
(`nixos-agent-test-vm` skill); the host store is mounted inside it, so the build is already
there.

```bash
socat -t 120 - UNIX-CONNECT:"$vm_socket" <<'PY'
code, out = sh("<out-path>/bin/<prog> --version")
assert code == 0, out
out
PY
```

Start with that: the version must be the *new* one, not empty and not the old one — §5's dead
stamp shows up here and nowhere else, as do a dead build date or git describe string. Then
the subcommand or flag §5 flagged, and the package's primary path. Where the host config
wraps the program, run the wrapper on `PATH` too; a divergence from the raw binary is the
override wiring. A library has nothing to run, so lean on its test suite instead; a service,
start the unit.

`ls -R <out-path>` catches §5's silently-built-nothing case and only reads the store, so it
runs anywhere. If a change looks like it might affect how the user runs the package, ask
rather than guess.

If the VM will not come up, say what blocked it and what you checked instead, rather than
falling back to running the output here.

## 7. Report the verdict — post nothing

**Never issue a write call against the PR** — no approve, no comment, no merge. Posting under
the user's account is their step.

Finish with a few lines saying what you'd do:

> **#<pr> <pkg>: <old> → <new> — would approve.**
> Version-only diff, no downgrade or pre-release. Upstream is dep bumps plus bug fixes, no
> breaking changes; license unchanged at the new tag. Built the bot's commit on x86_64-linux
> (route B); vendor FOD rebuilt from scratch and the output path matches the bot's. Ran it in
> the agent VM: prints the new version, and the wrapped and raw binaries agree;
> `passthru.tests.version` passes. ofborg green. Note:
> `meta.changelog` 404s at both versions — pre-existing, separate fix.

Always name the route: "downloaded it" and "built it" are different claims. Say the VM run
happened, or that it didn't.

Or `would request changes`, with the reason and what would need to happen first. Only claim
checks you actually ran; if you skipped the build, say so rather than implying a clean review.

If the user wants it posted, hand them the commands, and use upstream's template for the
review body, ticking only the boxes actually checked:

```markdown
##### Reviewed points

- [ ] package name fits guidelines
- [ ] package version fits guidelines
- [ ] package builds on ARCHITECTURE
- [ ] executables tested on ARCHITECTURE
- [ ] any change of upstream are verified
- [ ] the motives for any special packaging choices are documented
- [ ] all depending packages build
- [ ] patches have a comment describing either the upstream URL or a reason why the patch wasn't upstreamed
- [ ] patches that are remotely available are fetched rather than vendored

##### Possible improvements

##### Comments
```

Leave `all depending packages build` unticked unless route C actually ran.

## 8. Merge-bot eligibility

Worth a line in the verdict. Without a commit bit, commenting
`@NixOS/nixpkgs-merge-bot merge` is the only lever.

One constraint varies in practice: the PR must touch **only** `pkgs/by-name/*`. A package
living anywhere else is not eligible, and an approval there just waits for a committer. The
rest hold by construction for a bot bump on one's own package (`ci/README.md` lists them).

CI state when the comment lands does change the outcome. Green → merge queue. Pending or
missing → Auto Merge is enabled and it lands later unattended, so commenting then is a
decision to merge sight-unseen. Already failing → the bot does nothing and the command must be
repeated after a fix.

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
- [nixpkgs-update maintainer FAQ](https://github.com/NixOS/nixpkgs-update/blob/main/doc/nixpkgs-maintainer-faq.md#r-ryantm-opened-a-pr-for-my-package-what-do-i-do) — the four duties for a bot PR; the link the PR's maintainer ping points at. Also lists why a package stops getting updated or picks a wrong version (§5).
- [Nixpkgs/Automatic Updates](https://wiki.nixos.org/wiki/Nixpkgs/Automatic_Updates) — how r-ryantm picks versions and its failure modes.
- [nixpkgs-review README](https://github.com/Mic92/nixpkgs-review) — flags and subcommands.
