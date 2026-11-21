# SPDX-License-Identifier: Apache-2.0
"""Run from this directory: python3 -B test_sway_herdr_nav.py"""

import unittest

import sway_herdr_nav as nav


class FakeDesktop:
    def __init__(self, herdr=True):
        self.window = {"id": 1, "app_id": "herdr-app" if herdr else "foot"}
        self.other = {"id": 2, "app_id": "foot" if herdr else "herdr-app"}
        self.state = {"space": "s", "tab": "t", "focused_pane": "a", "overlays": []}
        self.calls = []
        self.status_calls = 0
        self.next_pane = "a"
        self.change_tab = False

    def focused_window(self):
        return self.window

    def status(self):
        self.status_calls += 1
        return dict(self.state)

    def move_pane(self, direction):
        self.calls.append(("pane", direction))
        self.state["focused_pane"] = self.next_pane
        if self.change_tab:
            self.state["tab"] = "other-tab"

    def move_window(self, direction):
        self.calls.append(("sway", direction))
        self.window = self.other


class NavigationTests(unittest.TestCase):
    def test_move_within_herdr(self):
        desktop = FakeDesktop()
        desktop.next_pane = "b"
        nav.navigate(desktop, "right")
        self.assertEqual(desktop.calls, [("pane", "right")])

    def test_leave_herdr_at_edge(self):
        desktop = FakeDesktop()
        nav.navigate(desktop, "right")
        self.assertEqual(desktop.calls, [("pane", "right"), ("sway", "right")])

    def test_entering_herdr_preserves_selection_without_querying_it(self):
        desktop = FakeDesktop(herdr=False)
        nav.navigate(desktop, "right")
        self.assertEqual(desktop.state["focused_pane"], "a")
        self.assertEqual(desktop.calls, [("sway", "right")])
        self.assertEqual(desktop.status_calls, 0)

    def test_leave_popups_alone(self):
        desktop = FakeDesktop()
        desktop.state["overlays"] = ["palette"]
        nav.navigate(desktop, "down")
        self.assertEqual(desktop.calls, [])

    def test_unknown_pane_is_not_an_edge(self):
        desktop = FakeDesktop()
        desktop.state["focused_pane"] = None
        nav.navigate(desktop, "left")
        self.assertEqual(desktop.calls, [])

    def test_tab_change_does_not_move_window(self):
        desktop = FakeDesktop()
        desktop.change_tab = True
        nav.navigate(desktop, "left")
        self.assertEqual(desktop.calls, [("pane", "left")])

    def test_failure_does_not_move_window(self):
        desktop = FakeDesktop()

        def unavailable():
            raise TimeoutError("Herdr is busy")

        desktop.status = unavailable
        with self.assertRaises(TimeoutError):
            nav.navigate(desktop, "right")
        self.assertEqual(desktop.calls, [])


if __name__ == "__main__":
    unittest.main()
