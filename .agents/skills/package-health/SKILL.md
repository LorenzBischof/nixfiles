---
name: package-health
description: Use when auditing the health of the nixpkgs packages a configuration depends on — finding packages nixpkgs has stopped updating, packages with unresolved CVEs, and packages whose upstream has stopped releasing — to decide whether to adopt, replace, or accept each one.
---

# Package health

Two questions, and nothing else:

1. **Is nixpkgs failing to update a package?** Master is behind upstream, and
   something is blocking the bump.
2. **Is upstream itself unhealthy?** Unresolved CVEs, or a project that has
   stopped releasing.

**The baseline is nixpkgs master, never our pin.** Whether a host has rebuilt
lately is not a package-health question, and treating it as one produces false
alarms: a routine flake.lock age reads as a fleet-wide emergency. `gather.py`
compares upstream against nixkeeper's `nixVersion` (master) and falls back to our
evaluated version only for packages nixkeeper does not track, saying so when it
does. Don't audit the age of the `nixpkgs` input, and don't reason about what
"our pin is missing".

The configuration is still what decides *which* packages matter and *how much*:
`inventory.nix` finds the packages these hosts actually use, and `service` /
`system` / `home` plus the module config decide whether a vulnerable code path is
even reachable.

```bash
.agents/skills/package-health/gather.py --host framework --host nas --host vps --no-cache
.agents/skills/package-health/gather.py --host vps --package grafana-alloy
.agents/skills/package-health/gather.py --host nas --all --json /tmp/package-health.json
```

Requires `nix`, `curl`, `git`, and authenticated `gh`. The cache under
`$XDG_CACHE_HOME/package-health` has no expiry and includes the inventory: use
`--no-cache` for a fresh sweep or after configuration changes; reuse it for analysis
of the same sweep. Run `jj st` after edits before evaluating the flake, and note
that `.agents/skills` needs the Bash sandbox disabled to write.

Read the `Package health review` note in Basic Memory before a sweep to see what was
outstanding. It is a worklist of packages only: it carries no method and no history,
and nothing in it substitutes for current evidence.

## Read the evidence

- **CVEs:** nixkeeper's `vulnerabilities[].verdict` distinguishes `affected`,
  `fixed`, `patched` and `unconfirmed`, and is computed against master — which is
  the baseline, so the verdicts apply directly. Check the advisory, the patches in
  the pinned `package.nix`, and whether the code path is reachable in this
  configuration before judging exposure. A `nixVulnerable: true` row carrying **no
  `vulnerabilities` array** is flagged from repology's CPE match on the version
  string, not from an advisory: it gives you no IDs, it says nothing about nixpkgs'
  backported patches, and three of three such flags in the 2026-10-24 sweep were
  false. Resolve those by hand or report them as unresolved. If nixkeeper is
  unreachable the gatherer cannot provide the CVE tier at all; report that.
- **Version gaps:** use time since the oldest missing release, not the age of the
  packaged version. A single release from the last week is the bot's normal cadence
  and is summarized, not reported; persistent lag is the signal. Inspect the
  surrounding tags and dates for parallel branches, prereleases, or a failed tag
  convention. `outdatedSince` and `checkedAt` are not release dates. A newer version
  is not evidence that it fixes a particular CVE.
- **Release inactivity:** services get upstream queries even when nixkeeper calls
  them current — a dead project has a *zero* version gap, which is why nixkeeper
  called archived `readarr` "up to date". Check release dates and whether the repo is
  archived; old releases can mean a finished project or an abandoned one. A fetched
  page containing only prereleases does not prove the project never shipped a stable
  release.
- **Existing work:** read PR titles and diffs before proposing a bump. `openPRs`
  counts unrelated changes; `openPR` and update-tagged `otherPRs` identify known
  bumps. An open PR neither resolves exposure nor establishes that it is mergeable —
  two mergeable `dhcpcd` bumps sat unmerged for two months while five CVEs landed.
  A merged master PR or an open bump **explains** a gap; it never cancels it, so the
  gap is still measured and still reported.

The script sorts CVEs first, then version gaps. Extra PR searches use age/count
thresholds to bound requests; those thresholds do not decide the action. Maintainer
count alone says neither whether a package is healthy nor what blocks an update.
Choose an action from the actual blocker and the use in this configuration.

## Coverage and implementation constraints

`inventory.nix` covers service packages found via generated systemd unit names,
`environment.systemPackages`, and users' `home.packages`; it is not a complete
transitive closure. Other flake inputs and wrappers without usable source metadata
stay named as blind spots. Standalone home-manager configurations are not covered.

Approaches already measured and dropped — don't rebuild them: ranking by raw days
since our version shipped (it put seven *current* packages in the top ten of 203;
days missing ÷ the project's own median release gap is what separates a 97-day gap on
a 3-day release train from a 29-day one on a 219-day train); a tarball-host directory
tier (no finding across 66 of 214 packages, and a directory index cannot flag a
release candidate); fetching `nixpkgs-update` logs (nixkeeper's `update` block
supplies the same `outcome` / `failedBecause` / `excerpt`); and a
`gh api search/issues author:r-ryantm` step (told less than the log, tokenizes so it
needs exact-prefix filtering, and tripped GitHub's secondary rate limit per package).

In this environment `urllib` is blocked by the egress proxy (403) — use `curl` — and
`--json` needs an explicitly writable path, since `$TMPDIR` is unset in a
sandbox-disabled shell.

When changing the gatherer, preserve these constraints:

- Enumerating all `services.*.enable` options can abort on renamed options. The
  inventory uses unit names and deeply forces entries with `tryEval (toJSON ...)`.
- Source derivations identify upstream URLs. `nix derivation show` keys by derivation
  basename; handle both `structuredAttrs` and `env` fetcher attributes.
- `pkgs/by-name/<shard>/<name>/` identifies an attr; other directory names are
  candidates. When two inventoried packages claim one candidate at different versions
  the attr is ambiguous and nixpkgs is shipping parallel trains from one file — name
  it as a blind spot instead of ranking it, or `fuse` 2.9.9 reads as 3607 days behind
  `fuse-3.0.0`. A package with no `src` URL cannot have its tags dated, but its
  nixkeeper row still names the right attr, so report it when nixkeeper itself calls
  master outdated; an ambiguous attr makes even that untrustworthy, because the row
  describes a different package in the same file.
- Normalize tag prefixes/suffixes from the source URL before comparing versions; the
  URL carries *our* version, so derive the convention from that even though the
  comparison baseline is master. Keep only plain numeric tags: that one filter
  collapsed 10 of the 11 worst entries in a 99-package set to "current" with no false
  negative. Missing dates, filtered tags, and unrecognized conventions are limitations.
- Fetch nixkeeper rows before forge queries — the baseline comes from them. Always
  retain CVEs alongside pending PR evidence, and check service release inactivity
  independently of version lag.
- Report filtering is not acceptance. `--all` prints every inventoried record and
  `--package` selects by pname however healthy; rank by days behind before concluding
  that a sweep is clean.

## Write the result

Rewrite the `Package health review` note in place. The body above the final section
is a worklist the user reads to decide what to act on, and it holds nothing else:

- It is tables, one row per package that needs a decision — `package (host)` /
  `problem` / `decision` for the packages needing a call, and `package` / `gap` /
  `blocker` for the ones nixpkgs cannot bump without a human. Keep a cell to a
  sentence or two: the point is that the whole thing is scannable.
- Entries exist for three things only — nixpkgs is not updating the package, it is
  updating slowly with effectively no maintainer, or upstream is abandoned. A live
  CVE belongs inside the entry of the package it is stuck behind, never in a section
  of its own.
- A package moving on the bot's ordinary cadence, a merged or open bump, a patched,
  unreachable or unfixable vulnerability, a false positive: none of these appear in
  the worklist. "Already being fixed" is not a status worth reporting.
- No sweep history, no hosts or command lines, no account of what was checked or how,
  no past measurements, no narrative.

A package that no longer needs a decision is deleted from the note, not marked
resolved — never kept with a "resolved" marker.

### The carry-over section

End the note with `## Settled — don't re-derive (agent notes)`, addressed to the next
sweep rather than to the user. It exists so expensive judgments are not recomputed: a
CVE whose code path this configuration does not reach, a repology CPE flag already
proven false, a vulnerability with no upstream fix in existence, a project that is
finished rather than abandoned, a package whose lag is unmeasurable and does not yet
matter.

Write each as one line, in this shape:

```
- **<package> <version it was judged at>** — <the judgment>. **Recheck:** <the check>.
```

Both halves are mandatory, and each earns its place:

- **The version** — a judgment is about a version, never about a package. Without it
  the next sweep cannot tell whether the line still describes what is installed.
- **The recheck** must be *cheap*: a field this sweep already gathered (the version,
  the row's advisory IDs, its verdicts, the last-release date) or one grep over
  `hosts/` and `modules/`. Name the check, and name what its answer has to be.

If the premise cannot be reduced to a check that cheap, **leave the package out of
the note**. A line whose verification costs as much as the original analysis saves
nothing and goes stale silently, which is worse than re-deriving it. Note that how
expensive the judgment *was* does not matter — avahi's took a 21-patch audit, and its
recheck is "still 0.8, row still carries no `vulnerabilities` array".

Verify the premise, not the conclusion: an unchanged CVE ID or an age threshold does
not re-establish a judgment, and a carry-over line is a shortcut past gathering
evidence, never past judging it. Rewrite or delete a line whose premise no longer
holds; never append to one.

Nothing else earns a line there: not method, not gatherer limitations, not a
measurement, not a package the worklist above already covers.

Method findings, measured thresholds and gatherer limitations belong in this skill,
not in the note.
