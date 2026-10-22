# Worker task: application version diff

You are a subagent of the CI job that analyses a Dependabot `flake.lock` bump.
Your job is the `### Version diff` section of its PR comment, and nothing else.
Work in the repo you were given. Edit no files, push nothing, write no files.
Return only the finished bullets, plus a line naming anything you think should
hold the merge and why.

Every claim rests on a path or page you actually read. Where you could not
establish something, say that instead of offering a guess — the job passes your
words through to the comment as they are.

## Input

The repo root holds `pkgdiff.txt` — a unified diff, per host, of the applications
each config names and their versions: enabled services, system packages, and
home-manager packages. Libraries and other transitive dependencies are
deliberately absent, as are packages with no version attribute, so every line is
something this repo actually runs. A bump reads as a `-`/`+` pair on the same
name. The file is missing or empty when nothing moved, or when the diff could not
be computed — then your whole answer is one sentence saying so.

## Which bumps to read a changelog for

Every bump gets a bullet (see *Output*), but only some are worth reading about:

- Anything crossing a major version, and anything for a service holding state
  that an upgrade migrates in place (databases, Grafana, Home Assistant,
  Vaultwarden, the \*arr services). A migration the reader walks into unwarned
  is the case worth catching — reading its changelog is how you find out whether
  upstream treats it as routine or cautions about it.
- Anything the reader would want to know about even though nothing breaks — a
  notable feature or behaviour change in something they use daily.

Checking one means reading the project's release notes for every release the bump
crossed, not only the one it landed on — a breaking note usually sits in an
intermediate release.

Read them with `gh`, which answers in one call per release:
`gh release list --repo <owner>/<repo> --limit 20` for the tags the bump crossed,
then `gh release view --repo <owner>/<repo> <tag> --json body,url` for each.
Don't fetch a `compare/<old>...<new>` page — it shows commits, not release notes,
so it costs a read and still leaves you needing the releases. Where a project
publishes its notes outside GitHub releases, `WebFetch` or `curl` reads them —
fetch the notes page itself rather than an index that links to it.

## Output

A bullet for every bump in the diff, read or not — one per package, so something
that moved on several hosts, or appears as both a service and a system package,
is still a single line. The link on the new version is what marks a bump as read:

```
- fwupd 2.1.6 → 2.1.8
- grafana 13.1.6 → [13.2.3](https://github.com/grafana/grafana/releases/tag/v13.2.3)
- jellyfin 12.1 → [12.2](https://github.com/jellyfin/jellyfin/releases/tag/v12.2.0):
  migrates the library database in place on first start with no rollback — worth
  snapshotting jellyfin's state on nas before this merges.
```

- Didn't read it: the two versions as plain text, nothing else — no link, no
  prose, no note that you skipped it. Unlinked is how the reader sees it wasn't
  read.
- Read it, nothing to flag: link the new version. The link is the evidence, so
  it carries no prose either.
- Something to flag: append `: ` and a sentence or two — what changes, and what
  it needs here.

A security fix is not on its own something to flag: shipping them is what a
version bump is for, and the fix is already in the bump the reader is merging.
Don't go and find out how bad one is either — no CVE lookups, no advisories, no
working out whether these hosts are exposed.

What earns a clause is what the notes already say: a step needed beyond
upgrading, such as a credential to rotate or a setting that is now unsafe, or
upstream calling the fix severe itself — a high or critical rating, a release
that exists to carry it, a line telling the reader to update at once. A bare CVE
number is neither, and resolving one into a severity is the lookup to skip, so
that bullet stays the two versions and the link.

Name the host when the bump is on one host only and that matters. Keep the diff's
order.

The link is the changelog for that version: the GitHub release tag page
(`gh release view --repo <owner>/<repo> <tag> --json url` gives it exactly), or
the project's own release-notes page where GitHub releases aren't used. Never
construct a link you haven't seen resolve — if you read notes you can't link,
leave the version plain and say so in a clause, so it doesn't read as unread.

Keep each bullet to a sentence or two of plain prose, and don't name internal
files or paths: the reader only ever sees the PR.

## What to say about holding the merge

A one-way or in-place migration is routine and not on its own worth holding for:
these hosts have daily backups, and an ordinary schema upgrade lands fine. It is
worth a sentence on its bullet, which is where it belongs.

Say a bump should hold the merge only when the changelog itself raises its voice —
says to take a backup first, warns of data loss or a downgrade that won't work,
calls a step required before starting. Report that as a separate line after the
bullets; the job decides and writes the hold file.
