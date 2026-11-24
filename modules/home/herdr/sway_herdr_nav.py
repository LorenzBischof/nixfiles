# SPDX-License-Identifier: Apache-2.0
"""Navigate Herdr panes, then Sway windows when a pane cannot move further."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys


def command(*args):
    result = subprocess.run(args, check=True, capture_output=True, text=True, timeout=1)
    value = json.loads(result.stdout)
    if isinstance(value, dict) and value.get("error"):
        raise RuntimeError(value["error"])
    return value


def focused(node):
    if node.get("focused") and node.get("pid"):
        return node
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        found = focused(child)
        if found:
            return found
    return None


class Desktop:
    def focused_window(self):
        return focused(command("swaymsg", "-r", "-t", "get_tree"))

    def status(self):
        return command("herdr-app", "status")

    def move_pane(self, direction):
        command("herdr-app", "do", "pane.go", "--direction", direction)

    def move_window(self, direction):
        replies = command("swaymsg", "-r", "focus", direction)
        if not all(reply.get("success") for reply in replies):
            raise RuntimeError(f"Sway refused focus {direction}")


def pane_focus(status):
    return status.get("space"), status.get("tab"), status.get("focused_pane")


def ready(status):
    return not status.get("overlays") and bool(status.get("focused_pane"))


def navigate(desktop, direction):
    window = desktop.focused_window()
    if window and window.get("app_id") == "herdr-app":
        before = desktop.status()
        if not ready(before):
            return
        desktop.move_pane(direction)
        after = desktop.status()
        if not ready(after) or pane_focus(before) != pane_focus(after):
            return
    desktop.move_window(direction)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("direction", choices=("left", "right", "up", "down"))
    args = parser.parse_args()
    try:
        # Drop overlapping key repeats rather than queuing stale focus decisions.
        lock_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "sway-herdr-nav.lock"
        with lock_path.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            navigate(Desktop(), args.direction)
    except (
        OSError,
        ValueError,
        KeyError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as error:
        print(f"sway-herdr-nav: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
