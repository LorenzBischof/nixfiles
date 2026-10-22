#!/usr/bin/env python3
"""Gather package-health evidence for NixOS hosts.

    ./gather.py --host framework --host nas --host vps
    ./gather.py --host vps --package grafana-alloy
    ./gather.py --host nas --json out.json

Requires nix, curl, git and authenticated gh. Responses cache under
$XDG_CACHE_HOME/package-health; --no-cache refreshes inventory and remote data.
Review judgments and history belong in the Package health review note.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
INVENTORY = os.path.join(HERE, "inventory.nix")
TODAY = datetime.date.today()

CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "package-health",
)

ARCHIVE_SUFFIX = re.compile(r"\.(tar\.(gz|xz|bz2|zst|lz)|tgz|txz|tbz2|zip|tar|deb)$")


# Compare only plain numeric tags after removing the source URL’s tag convention.
NUMERIC = re.compile(r"^[0-9][0-9.]*[a-z]?$")


# Limits extra PR searches, not acceptance or report visibility.
STALE_DAYS = 90


NIXKEEPER = os.environ.get("NIXKEEPER_DATA", "https://nixkeeper.com/data/")


NK_STATUS = {
    "f": "failed",
    "m": "outdated, update merged on master",
    "o": "outdated",
    "u": "up to date",
    "n": "cannot be compared",
}


def run(cmd, timeout=180):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    return p.returncode, p.stdout, p.stderr


def cached(key, produce, use_cache=True):
    path = os.path.join(CACHE, hashlib.sha1(key.encode()).hexdigest() + ".json")
    if use_cache and os.path.exists(path):
        with open(path) as fh:
            return json.load(fh)
    value = produce()

    # Failed fetches must not become persistent cache hits.
    if isinstance(value, dict) and "_error" in value:
        return value
    os.makedirs(CACHE, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(value, fh)
    os.replace(tmp, path)
    return value


def gh_api(path, use_cache=True):
    def produce():
        rc, out, err = run(["gh", "api", path])
        if rc != 0:
            return {"_error": err.strip()[:200]}
        try:
            return json.loads(out)
        except ValueError:
            return {"_error": "unparseable response"}

    return cached("gh:" + path, produce, use_cache)


MAX_BODY = 64 * 1024 * 1024


def http_text(url, use_cache=True, timeout=90):
    def produce():
        rc, out, err = run(
            ["curl", "-sSL", "--max-time", str(timeout), url], timeout=timeout + 30
        )
        if rc != 0:
            return {"_error": err.strip()[:200]}
        if len(out) > MAX_BODY:
            return {"_error": f"body over {MAX_BODY} bytes"}
        return {"_text": out}

    return cached("http:" + url, produce, use_cache)


def http_json(url, use_cache=True):
    got = http_text(url, use_cache)
    if "_error" in got:
        return got
    try:
        return json.loads(got["_text"])
    except ValueError:
        return {"_error": "not JSON"}


def ls_remote(url, use_cache=True):
    def produce():
        rc, out, err = run(["git", "ls-remote", "--tags", "--refs", url], timeout=120)
        if rc != 0:
            return {"_error": err.strip()[:200]}
        return {
            "tags": [
                line.split("refs/tags/")[-1]
                for line in out.splitlines()
                if "refs/tags/" in line
            ]
        }

    return cached("ls:" + url, produce, use_cache)


def nk_status_text(letter: str):
    if not letter:
        return None
    text = NK_STATUS.get(letter[0], letter)
    return text + ", vulnerable" if letter.endswith("v") else text


def nk_names(use_cache=True):
    """Fetch the status index before querying individual packages or forges."""
    got = http_text(NIXKEEPER + "names.json", use_cache)
    if "_error" in got:
        return None
    try:
        entries = json.loads(got["_text"])["names"]
    except (ValueError, KeyError):
        return None
    return {e[0].lower(): e[1] for e in entries}


def nk_index(use_cache=True):
    got = http_json(NIXKEEPER + "index.json", use_cache)
    return got if isinstance(got, dict) and "_error" not in got else {}


def nk_row(attr: str, shard_count: int, use_cache=True):
    """Fetch the shard containing this attr and return its row."""
    import zlib

    shard = zlib.crc32(attr.encode()) % (shard_count or 1)
    got = http_json(f"{NIXKEEPER}rows/{shard}.json", use_cache)
    if not isinstance(got, dict) or "packages" not in got:
        return None
    for candidate in got["packages"]:
        if candidate.get("name") == attr:
            return candidate
    return None


def apply_nk_row(p, row):
    """Keep nixkeeper data under nk_* keys, separate from local measurements."""
    p["nk_version"] = row.get("nixVersion")
    p["nk_reference"] = row.get("refVersion")
    p["nk_maintainers"] = row.get("maintainers") or []
    p["nk_source"] = row.get("source")

    # openPRs counts unrelated changes too; only openPR and tagged updates are bumps.
    if row.get("openPR"):
        pr = row["openPR"]
        p["nk_open_pr"] = {
            "number": pr.get("number"),
            "from": pr.get("from"),
            "to": pr.get("to"),
            "base": pr.get("base"),
        }

    p["nk_dup_prs"] = sorted(
        o["number"]
        for o in (row.get("otherPRs") or [])
        if o.get("kind") == "update" and o.get("number")
    )

    if row.get("masterPR"):
        pr = row["masterPR"]
        p["nk_master_pr"] = {"number": pr.get("number")}

    if row.get("update"):
        up = row["update"]
        p["nk_update"] = {
            "outcome": up.get("outcome"),
            "failed_because": up.get("failedBecause"),
            "from": up.get("from"),
            "to": up.get("to"),
            "date": up.get("date"),
            "excerpt": up.get("excerpt") or [],
        }

    # The boolean nixVulnerable cannot substitute for advisory dispositions.
    vulns = row.get("vulnerabilities") or []
    if vulns:
        p["nk_vulns"] = [
            {
                "id": v.get("id"),
                "severity": v.get("severity"),
                "score": v.get("score"),
                "verdict": v.get("verdict"),
                "summary": (v.get("summary") or "")[:120],
                "releases": v.get("releases") or {},
            }
            for v in sorted(vulns, key=lambda v: -(v.get("score") or 0))
        ]
        p["nk_vulns_affected"] = [
            v for v in p["nk_vulns"] if v["verdict"] == "affected"
        ]


def vkey(s: str):
    """Sort key where digits compare numerically and never against letters."""
    return [
        (0, int(x), "") if x.isdigit() else (1, 0, x)
        for x in re.findall(r"\d+|[A-Za-z]+", s)
    ]


def vlt(a: str, b: str) -> bool:
    return vkey(a) < vkey(b)


def tag_convention(url: str, version: str):
    """The tag shape the source URL spells, as (prefix, suffix) around the version.

    `.../archive/refs/tags/fuse-2.9.9.tar.gz` -> ("fuse-", ""), which is what
    lets fuse 2.9.9 be compared against the fuse-3.x line. fetchFromGitLab's URL
    is already an API URL and carries its tag in ?sha=.
    """
    tag = None
    query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    if "sha" in query:
        tag = urllib.parse.unquote(query["sha"][0]).removeprefix("refs/tags/")
    else:
        m = re.search(
            r"/(?:archive/refs/tags|archive|releases/download|-/archive)/([^/?]+)", url
        )
        if m:
            tag = ARCHIVE_SUFFIX.sub("", m.group(1))
    if tag and version and version in tag:
        i = tag.index(version)
        return tag, tag[:i], tag[i + len(version) :]
    return tag, "", ""


def strip_tag(tag: str, prefix: str, suffix: str) -> str:
    if prefix and tag.startswith(prefix):
        tag = tag[len(prefix) :]
    if suffix and tag.endswith(suffix):
        tag = tag[: -len(suffix)]
    if not prefix and re.match(r"^[vV]\d", tag):
        tag = tag[1:]
    return tag


def days_since(iso: str):
    if not iso:
        return None
    try:
        return (TODAY - datetime.date.fromisoformat(iso)).days
    except ValueError:
        return None


def rank(version: str, items, below=3, above=5):
    """items: [(stripped, iso-date-or-"", raw-tag)]. Returns the evidence block."""
    dropped = [raw for stripped, _, raw in items if not NUMERIC.match(stripped)]
    kept = [it for it in items if NUMERIC.match(it[0])]
    out = {"dropped": len(dropped), "dropped_sample": sorted(dropped)[:6]}
    if not kept:
        out["status"] = "no-comparable-tags"
        return out

    kept.sort(key=lambda it: vkey(it[0]))
    out["newest"] = kept[-1][2]

    out["newest_version"] = kept[-1][0]
    out["newest_date"] = kept[-1][1]
    out["upstream_quiet_days"] = days_since(kept[-1][1])

    stripped = [it[0] for it in kept]
    out["exact"] = version in stripped
    out["status"] = "ok" if out["exact"] else "version-not-offered-upstream"

    newer = [it for it in kept if vlt(version, it[0])]
    out["behind"] = len(newer)
    if newer:
        # Age the oldest missing release, not the newest release.
        out["missing"] = newer[0][2]
        out["days"] = days_since(newer[0][1])
    else:
        out["days"] = 0

    pivot = next(
        (n for n, v in enumerate(stripped) if not vlt(v, version)), len(stripped)
    )
    lo, hi = max(0, pivot - below), min(len(kept), pivot + above + 1)
    out["window"] = [
        ("*%s*" % it[2] if it[0] == version else it[2])
        + (" (%s)" % it[1] if it[1] else "")
        for it in kept[lo:hi]
    ]

    return out


def inventory(flake: str, host: str, use_cache=True):
    with open(INVENTORY) as fh:
        expr = fh.read()

    def produce():
        rc, out, err = run(
            [
                "nix",
                "eval",
                "--json",
                f"{flake}#nixosConfigurations.{host}.config",
                "--apply",
                expr,
            ],
            timeout=900,
        )
        if rc != 0:
            return {"_error": err.strip()[-600:]}
        return {"entries": json.loads(out)}

    got = cached(
        f"inv:{flake}:{host}:{hashlib.sha1(expr.encode()).hexdigest()}",
        produce,
        use_cache,
    )
    if "_error" in got:
        sys.exit(f"nix eval failed for {host}:\n{got['_error']}")
    return [dict(json.loads(line), host=host) for line in got["entries"]]


def merge(all_entries):
    by_key = {}
    for e in all_entries:
        key = (e["name"], e["version"])
        slot = by_key.setdefault(
            key,
            {
                "name": e["name"],
                "version": e["version"],
                "src": e["src"],
                "position": e["position"],
                "sources": set(),
                "hosts": set(),
            },
        )
        slot["sources"].add(e["source"])
        slot["hosts"].add(e["host"])
    out = []
    for slot in by_key.values():
        slot["sources"] = sorted(slot["sources"])
        slot["hosts"] = sorted(slot["hosts"])
        out.append(slot)
    return sorted(out, key=lambda p: p["name"])


def split_by_origin(packages):
    """The dominant /nix/store position prefix is nixpkgs; the rest are other inputs."""
    prefixes = {}
    for p in packages:
        m = re.match(r"(/nix/store/[a-z0-9]+-[^/]+)/", p["position"] or "")
        if m:
            prefixes[m.group(1)] = prefixes.get(m.group(1), 0) + 1
    if not prefixes:
        return packages, [], None
    nixpkgs = max(prefixes, key=lambda k: prefixes[k])
    mine, foreign = [], []
    for p in packages:
        (mine if (p["position"] or "").startswith(nixpkgs) else foreign).append(p)
    for p in mine:
        p["attrdir"] = p["position"][len(nixpkgs) :]
    return mine, foreign, nixpkgs


def attr_candidates(attrdir: str):
    """A position under pkgs/by-name/<shard>/<name>/ *is* attr <name>, by nixpkgs
    rule. Elsewhere the parent directory is only a candidate -- but step 3 uses
    it to build a log URL that echoes the real attrpath back, so a wrong guess
    announces itself."""
    m = re.match(r"^/pkgs/by-name/[^/]+/([^/]+)/", attrdir or "")
    if m:
        return [m.group(1)], True
    parts = [p for p in (attrdir or "").split("/") if p]
    if len(parts) >= 2:
        return [parts[-2]], False
    return [], False


def flag_ambiguous_attrs(packages):
    """nixpkgs ships parallel release trains from one file -- fuse 2.9.9 beside
    fuse3 3.18.2 out of one common.nix -- and a position yields the same attr
    candidate for both. Ranking either against the other's tags invents a gap
    (fuse read as "3607 days behind fuse-3.0.0"), so report the ambiguity.
    by-name attrs are certain and unique, so only candidates can collide."""
    versions = {}
    for p in packages:
        if p.get("attrs") and not p.get("attr_certain"):
            versions.setdefault(p["attrs"][0], set()).add(p["version"])
    for p in packages:
        claimed = versions.get((p.get("attrs") or [None])[0]) or set()
        if len(claimed) > 1:
            p["attr_ambiguous"] = sorted(claimed)


def resolve_source_urls(packages, use_cache=True):
    """One batched `nix derivation show` over the drvPaths step 1 already
    collected -- 197 of 200 in 0.1s. Do not re-`nix eval` per package."""
    drvs = sorted({p["src"] for p in packages if p["src"]})
    urls = {}
    if drvs:

        def produce():
            rc, out, err = run(["nix", "derivation", "show"] + drvs, timeout=600)
            if rc != 0:
                return {"_error": err.strip()[-400:]}
            return json.loads(out)

        shown = cached(
            "drvshow:" + hashlib.sha1("\0".join(drvs).encode()).hexdigest(),
            produce,
            use_cache,
        )
        if "_error" in shown:
            sys.exit("nix derivation show failed:\n" + shown["_error"])

        for drv, body in shown.get("derivations", {}).items():
            drv = os.path.basename(drv)
            sa, env = body.get("structuredAttrs") or {}, body.get("env") or {}

            raw = (
                sa.get("urls")
                or sa.get("url")
                or env.get("urls")
                or env.get("url")
                or ""
            )
            if isinstance(raw, list):
                raw = raw[0] if raw else ""
            urls[drv] = raw.split(" ")[0]
    for p in packages:
        p["url"] = urls.get(os.path.basename(p["src"]), "") if p["src"] else ""
    return packages


def classify_forge(url: str) -> str:
    if not url:
        return "none"
    if url.startswith("https://github.com/"):
        return "github"
    if re.match(r"https?://[^/]+/api/v4/projects/", url):
        return "gitlab"
    if re.match(r"https://(codeberg\.org|git\.outfoxxed\.me)/", url):
        return "gitea"
    if "sr.ht" in url or re.match(r"https?://\S+?\.git(?:$|/)", url):
        return "git"
    return "tarball"


def upstream_github(p, use_cache):
    m = re.match(r"https://github\.com/([^/]+)/([^/]+)", p["url"])
    owner, repo = m.group(1), m.group(2).removesuffix(".git")
    p["repo"] = f"{owner}/{repo}"
    releases = gh_api(f"repos/{owner}/{repo}/releases?per_page=100", use_cache)
    if isinstance(releases, list):
        stable = [r for r in releases if not r["prerelease"] and not r["draft"]]
        p["prerelease_only"] = bool(releases) and not stable

        usable = stable or [r for r in releases if not r["draft"]]
        if usable:
            p["evidence"] = "github releases" + ("" if stable else " (all prerelease)")
            return rank(
                baseline(p),
                [
                    (
                        strip_tag(r["tag_name"], p["prefix"], p["suffix"]),
                        r["published_at"][:10],
                        r["tag_name"],
                    )
                    for r in usable
                ],
            )

    got = ls_remote(f"https://github.com/{owner}/{repo}", use_cache)
    if "_error" in got:
        return {"status": "upstream-unreachable", "error": got["_error"]}
    p["evidence"] = "git tags (no dates)"
    return rank(
        baseline(p),
        [(strip_tag(t, p["prefix"], p["suffix"]), "", t) for t in got["tags"]],
    )


def open_nixpkgs_prs(p, use_cache=True):
    """Search titles for this attr; matches are evidence, not confirmed bumps."""
    attr = (p.get("attrs") or [p["name"]])[0]
    q = f"repo:NixOS/nixpkgs is:pr is:open in:title {attr}"
    got = gh_api("search/issues?per_page=20&q=" + urllib.parse.quote(q), use_cache)
    if not isinstance(got, dict) or "items" not in got:
        return

    # Hyphens and dots are attr characters, not token boundaries.
    word = re.compile(r"(?:^|[\s:,+/(])%s(?=[\s:,+/)]|$)" % re.escape(attr), re.I)
    p["open_prs"] = [
        {"number": it["number"], "title": it["title"]}
        for it in got["items"]
        if word.search(it.get("title") or "")
    ][:6]


def upstream_gitlab(p, use_cache):
    m = re.match(r"(https?://[^/]+)/api/v4/projects/([^/]+)/", p["url"])
    host, proj = m.group(1), m.group(2)
    p["repo"] = f"{host}/{urllib.parse.unquote(proj)}"
    got = http_json(
        f"{host}/api/v4/projects/{proj}/repository/tags?per_page=100", use_cache
    )
    if not isinstance(got, list):
        return {"status": "upstream-unreachable", "error": str(got)[:200]}
    p["evidence"] = "gitlab tags"
    return rank(
        baseline(p),
        [
            (
                strip_tag(t["name"], p["prefix"], p["suffix"]),
                (t.get("commit", {}).get("created_at") or "")[:10],
                t["name"],
            )
            for t in got
        ],
    )


def upstream_gitea(p, use_cache):
    m = re.match(r"(https://[^/]+)/([^/]+)/([^/]+)", p["url"])
    host, owner, repo = m.group(1), m.group(2), m.group(3)
    p["repo"] = f"{host}/{owner}/{repo}"
    got = http_json(f"{host}/api/v1/repos/{owner}/{repo}/tags?limit=100", use_cache)
    if not isinstance(got, list):
        return {"status": "upstream-unreachable", "error": str(got)[:200]}
    p["evidence"] = "gitea tags"
    return rank(
        baseline(p),
        [
            (
                strip_tag(t["name"], p["prefix"], p["suffix"]),
                (t.get("commit", {}).get("created") or "")[:10],
                t["name"],
            )
            for t in got
        ],
    )


def upstream_git(p, use_cache):
    url = p["url"]
    if "sr.ht" in url:
        m = re.match(r"https://git\.sr\.ht/(~[^/]+/[^/]+)", url)
        git_url = "https://git.sr.ht/" + m.group(1)
    else:
        git_url = url.split(".git")[0] + ".git"
    p["repo"] = git_url
    got = ls_remote(git_url, use_cache)
    if "_error" in got:
        return {"status": "upstream-unreachable", "error": got["_error"]}
    p["evidence"] = "git tags (no dates)"
    return rank(
        baseline(p),
        [(strip_tag(t, p["prefix"], p["suffix"]), "", t) for t in got["tags"]],
    )


FORGES = {
    "github": upstream_github,
    "gitlab": upstream_gitlab,
    "gitea": upstream_gitea,
    "git": upstream_git,
}


INCOMPARABLE = ("no-source-url", "ambiguous-attr")


def baseline(p):
    """The version upstream is compared against: nixpkgs master.

    The audit asks whether nixpkgs is keeping a package current and whether
    upstream is still alive -- not whether a host has rebuilt lately. So master
    is the baseline, and our evaluated version is only the fallback for the
    packages nixkeeper does not track.
    """
    nk = p.get("nk_version")
    p["baseline_from"] = "nixkeeper master" if nk else "our evaluation"
    p["baseline"] = nk or p["version"]
    return p["baseline"]


def is_lead(p) -> bool:
    """Include CVEs, gaps, service release inactivity, and incomplete evidence."""
    if p.get("nk_vulns_affected"):
        return True
    # Without a src URL we cannot date tags, but nixkeeper's row still names the
    # attr correctly, so its own "outdated" is reportable on its authority alone.
    # An ambiguous attr makes even that untrustworthy: the row is about a
    # different package in the same file.
    if p.get("status") == "ambiguous-attr":
        return False
    if p.get("status") == "no-source-url":
        return (p.get("nk") or "").startswith("outdated")
    if (p.get("nk") or "") not in ("", "up to date"):
        return True
    if (p.get("behind") or 0) > 0:
        return True

    if quiet_service(p):
        return True
    return p.get("status") not in ("ok", None)


SUMMARY_KINDS = (
    "release newer than the bot cadence",
    "bump in flight",
    "no newer release observed",
)


# nixpkgs-update runs continuously, so a single release from the last few days
# says nothing about whether nixpkgs is keeping up -- 13 of this estate's 14
# sub-week gaps were exactly that. Persistent lag is the signal.
BOT_CADENCE_DAYS = 7


def fresh_release(p):
    days = p.get("days")
    return p.get("behind") == 1 and days is not None and days <= BOT_CADENCE_DAYS


def cve_label(v) -> str:
    """Format an advisory without printing absent severity or score fields."""
    return " ".join(
        str(x) for x in (v["id"], v.get("severity"), v.get("score")) if x is not None
    )


def bump_in_flight(p):
    """A merged master PR, an open bump, or a bot branch. It explains a gap and
    never cancels one, so a package with a measured gap is reported regardless."""
    if p.get("nk_vulns_affected"):
        return False
    return (
        bool(p.get("nk_master_pr"))
        or bool(pending_bump(p))
        or (
            (p.get("nk_update") or {}).get("outcome")
            in ("prExists", "prOpened", "branchExists")
        )
    )


def pending_bump(p):
    """Describe known bump PRs independently of vulnerability status."""
    pr = p.get("nk_open_pr")
    dups = p.get("nk_dup_prs") or []
    if not pr and not dups:
        return None
    if not pr:
        return "a bump PR is open (#%s)" % dups[0]
    extra = (" (also #%s)" % ", #".join(str(d) for d in dups)) if dups else ""
    return "PR #%s is open on %s, %s -> %s%s" % (
        pr["number"],
        pr.get("base") or "master",
        pr.get("from"),
        pr.get("to"),
        extra,
    )


def has_gap(p):
    return (p.get("behind") or 0) > 0 or (p.get("nk") or "").startswith("outdated")


def quiet_service(p):
    """An age threshold selects evidence for review; it cannot prove abandonment."""
    quiet = p.get("upstream_quiet_days") or 0
    return "service" in p["sources"] and (
        quiet > 730 or (p.get("prerelease_only") and quiet > 365)
    )


def summary_kind(p):
    """Summarize routine records without hiding CVEs, conflicts, or missing data."""
    if (
        p.get("nk_vulns_affected")
        or quiet_service(p)
        or p.get("status") not in ("ok", None)
    ):
        return None
    if fresh_release(p):
        return "release newer than the bot cadence"
    if has_gap(p) or p.get("nk") == "cannot be compared":
        return None
    if bump_in_flight(p):
        return "bump in flight"
    if p.get("nk") == "up to date" or (p.get("exact") and p.get("behind") == 0):
        return "no newer release observed"
    return None


def needs_pr_search(p):
    """Bound extra searches by evidence, independently of report wording."""
    if pending_bump(p):
        return False
    if quiet_service(p):
        return True
    if p.get("nk_vulns_affected"):
        return has_gap(p)
    if bump_in_flight(p):
        return False
    days = p.get("days")
    return has_gap(p) and (
        days >= STALE_DAYS if days is not None else (p.get("behind") or 0) >= 2
    )


def evidence_summary(p):
    facts = []
    affected = p.get("nk_vulns_affected") or []
    if affected:
        facts.append(f"{len(affected)} CVE(s) marked affected by nixkeeper")
    if p.get("behind"):
        days = p.get("days")
        age = (
            f"{days}d behind {p.get('missing') or 'an observed release'}"
            if days is not None
            else "release dates unavailable"
        )
        facts.append(f"{p['behind']} newer version(s), {age}")
    elif (p.get("nk") or "").startswith("outdated"):
        facts.append("nixkeeper reports a newer version; no newer tag observed here")
    elif p.get("nk") == "up to date" or (p.get("exact") and p.get("behind") == 0):
        facts.append("no newer release observed")
    if "service" in p["sources"] and p.get("upstream_quiet_days") is not None:
        facts.append(f"newest observed release {p['upstream_quiet_days']}d ago")
    if p.get("prerelease_only"):
        facts.append("fetched releases are all prereleases")
    if p.get("nk_master_pr"):
        facts.append(f"PR #{p['nk_master_pr']['number']} merged on master")
    if not facts:
        facts.append(
            f"comparison status: {p.get('status') or p.get('nk') or 'unknown'}"
        )
    return "; ".join(facts)


def render(p) -> str:
    bits = [f"[{','.join(p['sources'])}]", f"hosts={','.join(p['hosts'])}"]

    lines = [
        f"### {p['name']} {p.get('baseline') or p['version']}  {'  '.join(bits)}",
        f"    evidence     : {evidence_summary(p)}",
    ]

    for v in (p.get("nk_vulns_affected") or [])[:6]:
        lines.append(f"    CVE          : {cve_label(v)}")
        if v["summary"]:
            lines.append(f"                   {v['summary']}")

    pend = pending_bump(p)
    if pend:
        lines.append(f"    pending      : {pend}")

    for pr in p.get("open_prs") or []:
        lines.append(f"    open PR      : #{pr['number']} {pr['title']}")

    if p.get("window"):
        line = "    upstream     : " + ", ".join(p["window"])
        quiet, newest = p.get("upstream_quiet_days"), p.get("newest") or "\0"
        if quiet is None:
            pass
        elif p["window"][-1].lstrip("*").startswith(newest):
            line += f"  <- newest, {quiet}d ago"
        else:
            line += f"  ... newest {newest}, {quiet}d ago"
        lines.append(line)
    elif p.get("newest_date"):
        lines.append(
            f"    newest rel   : {p.get('newest')} on {p['newest_date']}"
            f" ({p.get('upstream_quiet_days')}d ago)"
        )

    nk = []

    if p.get("nk"):
        nk.append(f"status {p['nk']}")

    if p.get("nk_reference") and p.get("nk_reference") != p.get("newest_version"):
        nk.append(f"upstream {p['nk_reference']} per nixkeeper")

    if nk:
        lines.append("    nixkeeper    : " + " | ".join(nk))

    if p.get("nk_source"):
        lines.append(f"    package.nix  : {p['nk_source']}")

    update = p.get("nk_update")
    if update and update.get("outcome") not in (None, "noChange"):
        got = f"{update.get('date') or 'date unknown'} {update['outcome']}"
        if update.get("failed_because"):
            got += f" ({update['failed_because']})"
        if update.get("from") and update.get("to"):
            got += f" | tried {update['from']} -> {update['to']}"
        lines.append(f"    bot attempt  : {got}")
        for line in (update.get("excerpt") or [])[:2]:
            lines.append(f"                 | {str(line)[:150]}")

    ev = []
    if p.get("status") not in ("ok", None):
        ev.append(f"status {p['status']}")

    if p.get("baseline_from") == "our evaluation" and p.get("behind") is not None:
        ev.append("baseline is our evaluation, not nixkeeper master")
    if p.get("tag") and not (
        p.get("prefix") is not None and p["version"] in (p["tag"] or "")
    ):
        ev.append(f"tag {p['tag']} -- convention NOT derived, comparison is blind")
    if p.get("dropped"):
        ev.append(f"{p['dropped']} dropped: {', '.join(p['dropped_sample'])}")

    attrs, certain = p.get("attrs") or [], p.get("attr_certain")
    if attrs and not (certain and attrs[0] == p["name"]):
        ev.append(
            f"attr {attrs[0]}" + ("" if certain else " (candidate, from position)")
        )
    if ev:
        lines.append(
            "    caveat       : via %s | %s"
            % (p.get("evidence", "nixkeeper only"), " | ".join(ev))
        )
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--host",
        action="append",
        required=True,
        help="nixosConfiguration to audit (repeatable)",
    )
    ap.add_argument("--flake", default=".")
    ap.add_argument(
        "--package", action="append", help="report only these pnames, however healthy"
    )
    ap.add_argument(
        "--all", action="store_true", help="print every inventoried nixpkgs record"
    )
    ap.add_argument("--no-cache", action="store_true", help="refetch everything")
    ap.add_argument("--json", metavar="FILE", help="also write all records as JSON")
    args = ap.parse_args()
    use_cache = not args.no_cache

    entries = []
    for host in args.host:
        print(f"# evaluating {host} ...", file=sys.stderr)
        entries += inventory(args.flake, host, use_cache)
    packages = merge(entries)
    mine, foreign, prefix = split_by_origin(packages)
    print(
        f"# {len(packages)} packages: {len(mine)} from nixpkgs, {len(foreign)} from other "
        f"flake inputs (skipped)",
        file=sys.stderr,
    )

    resolve_source_urls(mine, use_cache)
    for p in mine:
        p["forge"] = classify_forge(p["url"])
        p["attrs"], p["attr_certain"] = attr_candidates(p.get("attrdir", ""))
        p["tag"], p["prefix"], p["suffix"] = tag_convention(p["url"], p["version"])
    flag_ambiguous_attrs(mine)

    print("# reading nixkeeper's package list ...", file=sys.stderr)
    known = nk_names(use_cache)
    shard_count = 0
    if known is None:
        print(
            "# nixkeeper unreachable; falling back to per-forge queries, with no "
            "CVE data",
            file=sys.stderr,
        )
    else:
        shard_count = nk_index(use_cache).get("shardCount") or 256
        for p in mine:
            if p.get("attrs"):
                p["nk"] = nk_status_text(known.get(p["attrs"][0].lower()))
        seen = sum(1 for p in mine if p.get("nk"))
        print(f"# nixkeeper tracks {seen} of {len(mine)}", file=sys.stderr)

    wanted = set(args.package or [])

    for p in mine:
        if (
            known is not None
            and p.get("nk")
            and p.get("attrs")
            and (
                p["name"] in wanted
                or "service" in p["sources"]
                or p["nk"] != "up to date"
            )
        ):
            print(f"# nixkeeper row for {p['attrs'][0]} ...", file=sys.stderr)
            row = nk_row(p["attrs"][0], shard_count, use_cache)
            if row:
                apply_nk_row(p, row)

    def needs_dates(p):
        if p["name"] in wanted:
            return True
        if p["forge"] == "none":
            return False

        # Current versions can belong to abandoned projects; always check services.
        if "service" in p["sources"]:
            return True
        return p.get("nk") != "up to date"

    for p in mine:
        if p["forge"] == "none":
            p["status"] = "no-source-url"
            p["evidence"] = "wrapper or generated derivation; not auditable"
            continue
        if p.get("attr_ambiguous"):
            p["status"] = "ambiguous-attr"
            p["evidence"] = (
                "one attr candidate (%s) for parallel release trains (%s); "
                "not comparable" % (p["attrs"][0], ", ".join(p["attr_ambiguous"]))
            )
            continue
        if p["forge"] == "tarball":
            p["status"] = "ok" if p.get("nk") == "up to date" else None
            p["evidence"] = "plain tarball host; nixkeeper status only, no dates"
            continue
        if not needs_dates(p):
            p["status"] = "ok"
            p["evidence"] = (
                "nixkeeper: master or PR status; dates not fetched"
                if bump_in_flight(p)
                else "nixkeeper: up to date"
            )
            continue
        print(f"# {p['name']} via {p['forge']} ...", file=sys.stderr)
        p.update(FORGES[p["forge"]](p, use_cache))

    leads = (
        [p for p in mine if p["name"] in wanted]
        if wanted
        else [p for p in mine if args.all or is_lead(p)]
    )

    def sort_key(p):
        return (
            -(bool(p.get("nk_vulns_affected"))),
            -(p.get("days") or 0),
            -(p.get("behind") or 0),
            p["name"],
        )

    leads.sort(key=sort_key)
    for p in leads:
        if needs_pr_search(p):
            print(f"# open nixpkgs PRs naming {p['name']} ...", file=sys.stderr)
            open_nixpkgs_prs(p, use_cache)

    report = [p for p in leads if args.all or wanted or not summary_kind(p)]
    print(
        f"\n# {len(report)} of {len(mine)} nixpkgs package records"
        f" ({TODAY}); {len(leads) - len(report)} summarized\n"
    )
    for p in report:
        print(render(p))
        print()

    if not args.all and not wanted:
        counts = [
            (k, len({p["name"] for p in leads if summary_kind(p) == k}))
            for k in SUMMARY_KINDS
        ]
        shown = [f"{n} {k}" for k, n in counts if n]
        if shown:
            print("# summarized: " + ", ".join(shown) + "  (--all for the records)")

    reported = {id(p) for p in leads}
    quiet = sorted(
        {p["name"] for p in mine if p.get("status") == "ok" and id(p) not in reported}
    )

    blind = sorted(
        {
            p["name"]
            for p in mine
            if p.get("status") in INCOMPARABLE and id(p) not in reported
        }
        | {p["name"] for p in foreign}
    )
    if quiet:
        print(f"# {len(quiet)} current per nixkeeper, or measured current here")
    if blind:
        print(
            f"# {len(blind)} not auditable (wrappers with no src of their own, "
            f"parallel release trains under one attr, and other flake inputs): "
            + ", ".join(blind)
        )
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(
                {
                    "generated": str(TODAY),
                    "nixpkgs_position_prefix": prefix,
                    "packages": mine,
                    "foreign": foreign,
                },
                fh,
                indent=1,
                default=list,
            )
        print(f"# full records -> {args.json}", file=sys.stderr)


if __name__ == "__main__":
    main()
