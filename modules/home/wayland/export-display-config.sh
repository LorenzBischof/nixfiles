#!/usr/bin/env bash

# Export current Sway display configuration as kanshi nix snippet

set -euo pipefail

# Check if running under Sway
if ! swaymsg -t get_outputs &>/dev/null; then
    echo "Error: Not running under Sway or swaymsg not available" >&2
    exit 1
fi

# Get outputs and generate nix snippet
echo "{"
echo "  profile.outputs = ["

swaymsg -t get_outputs | jq -r '.[] | select(.active) |
  (if .name == "eDP-1" then .name else (.make + " " + .model + " " + .serial) end) as $criteria |
  "    {\n" +
  "      criteria = \"" + $criteria + "\";\n" +
  "      mode = \"" + (.current_mode.width|tostring) + "x" + (.current_mode.height|tostring) + "@" + ((.current_mode.refresh / 1000)|floor|tostring) + "Hz\";\n" +
  "      position = \"" + ((.rect.x // .x)|tostring) + "," + ((.rect.y // .y)|tostring) + "\";\n" +
  "      scale = " + (.scale|tostring) + ";\n" +
  "    }"
'

echo "  ];"
echo "}"
