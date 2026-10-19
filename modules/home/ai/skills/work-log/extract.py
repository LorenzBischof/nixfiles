"""Condense a day's Claude Code and Codex session logs into short Markdown.

Raw transcripts contain thinking blocks, tool calls/results, and signatures
that are 10-100x bigger than the useful signal and blow an LLM's context
window. This script keeps only the user's own messages and whichever agent
message finishes a turn (the one right before the user's next message) —
in-progress chatter ("I'll check that now") is dropped entirely.
"""

import argparse
import json
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()

DEFAULT_MAX_CHARS = 600

# Codex prepends this to the first user message of every session; it is
# config, not something the user said.
CODEX_BOILERPLATE_PREFIXES = ("# AGENTS.md instructions", "<environment_context>")

# Claude Code slash-command/local-command plumbing, not something the user said.
CLAUDE_BOILERPLATE_PREFIXES = ("<local-command-caveat>", "<local-command-stdout>", "<command-name>")


def parse_ts(s: str) -> datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone()


def truncate(s: str, n: int) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def load_jsonl(path: Path):
    try:
        with path.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def recent_files(proj_dirs, day: date):
    """(proj_dir, path) pairs for *.jsonl files that could hold entries for `day`.

    Files are appended only while active, so one untouched near `day` can't hold it.
    """
    for proj_dir in proj_dirs:
        for path in proj_dir.glob("*.jsonl"):
            mtime = datetime.fromtimestamp(path.stat().st_mtime).date()
            if abs((mtime - day).days) <= 2:
                yield proj_dir, path


class Session:
    """One session's turns, filtered to a single target day."""

    def __init__(self, source: str, project: str):
        self.source = source
        self.project = project
        self.turns: list[tuple[datetime, str, str]] = []  # ts, speaker, text

    def add(self, ts: datetime, speaker: str, text: str):
        if text:
            self.turns.append((ts, speaker, text))

    def blocks(self, idle_gap: timedelta = timedelta(minutes=20)):
        """Split turns wherever the gap to the next one implies idle time, so
        a session left open for hours doesn't read as continuous work."""
        turns = sorted(self.turns, key=lambda t: t[0])
        block = [turns[0]]
        for turn in turns[1:]:
            if turn[0] - block[-1][0] > idle_gap:
                yield block
                block = []
            block.append(turn)
        yield block

    def render_block(self, block, max_chars: int) -> str:
        start, end = block[0][0], block[-1][0]
        lines = [f"## {start:%H:%M}-{end:%H:%M}  {self.project}  ({self.source})"]
        # Keep the user, and whichever agent message ends a turn (the last
        # one before the user's next message, or the block's end); drop
        # everything else — it's in-progress chatter ("I'll check that now").
        turn_end_idx = set()
        last_agent_idx = None
        for i, (_, speaker, _) in enumerate(block):
            if speaker == "You":
                if last_agent_idx is not None:
                    turn_end_idx.add(last_agent_idx)
                last_agent_idx = None
            else:
                last_agent_idx = i
        if last_agent_idx is not None:
            turn_end_idx.add(last_agent_idx)

        for i, (_, speaker, text) in enumerate(block):
            if speaker != "You" and i not in turn_end_idx:
                continue
            lines.append(f"- {speaker}: {truncate(text, max_chars)}")
        return "\n".join(lines)


def claude_sessions(day: date) -> list[Session]:
    root = HOME / ".claude" / "projects"
    sessions = []
    for proj_dir, path in recent_files(root.glob("*"), day):
        project = None
        session = Session("claude", proj_dir.name)
        for entry in load_jsonl(path):
            if entry.get("type") not in ("user", "assistant"):
                continue
            msg = entry.get("message", {})
            ts_raw = entry.get("timestamp")
            if not ts_raw:
                continue
            ts = parse_ts(ts_raw)
            if ts.date() != day:
                continue
            project = project or entry.get("cwd") or proj_dir.name
            session.project = project
            content = msg.get("content")
            if entry["type"] == "user":
                if (
                    isinstance(content, str)
                    and content.strip()
                    and not content.startswith(CLAUDE_BOILERPLATE_PREFIXES)
                ):
                    session.add(ts, "You", content)
            elif entry["type"] == "assistant":
                text = "".join(b.get("text", "") for b in content or [] if b.get("type") == "text")
                session.add(ts, "Agent", text)
        if session.turns:
            sessions.append(session)
    return sessions


def codex_sessions(day: date) -> list[Session]:
    root = HOME / ".codex" / "sessions"
    sessions = []
    for d in (day - timedelta(days=1), day, day + timedelta(days=1)):
        dir_ = root / f"{d:%Y}" / f"{d:%m}" / f"{d:%d}"
        for path in dir_.glob("*.jsonl"):
            session = Session("codex", "?")
            for entry in load_jsonl(path):
                if entry.get("type") == "session_meta":
                    session.project = entry.get("payload", {}).get("cwd", "?")
                    continue
                if entry.get("type") != "response_item":
                    continue
                payload = entry.get("payload", {})
                if payload.get("type") != "message":
                    continue
                ts_raw = entry.get("timestamp")
                if not ts_raw:
                    continue
                ts = parse_ts(ts_raw)
                if ts.date() != day:
                    continue
                role = payload.get("role")
                texts = [
                    c.get("text", "")
                    for c in payload.get("content", [])
                    if c.get("type") in ("input_text", "output_text")
                ]
                text = "".join(texts)
                if role == "user":
                    if not text.startswith(CODEX_BOILERPLATE_PREFIXES):
                        session.add(ts, "You", text)
                elif role == "assistant":
                    session.add(ts, "Agent", text)
            if session.turns:
                sessions.append(session)
    return sessions


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--date", default=date.today().isoformat(), help="YYYY-MM-DD, local time (default: today)")
    p.add_argument(
        "--max-chars",
        type=int,
        default=DEFAULT_MAX_CHARS,
        help="Truncation length for the user's messages and whichever agent message "
        "finishes a turn (default: %(default)s). Pass a large number (e.g. 100000) "
        "to re-run with no truncation on those.",
    )
    args = p.parse_args()
    day = date.fromisoformat(args.date)

    sessions = claude_sessions(day) + codex_sessions(day)
    # Flatten to blocks and sort globally: a session's blocks can be hours
    # apart, and different projects/sources interleave across the day.
    rendered = sorted(
        ((block[0][0], s.render_block(block, args.max_chars)) for s in sessions for block in s.blocks()),
        key=lambda pair: pair[0],
    )

    print(f"# Work log — {day.isoformat()}\n")
    if not rendered:
        print("No agent sessions found for this day.")
        return
    for _, text in rendered:
        print(text)
        print()


if __name__ == "__main__":
    main()
