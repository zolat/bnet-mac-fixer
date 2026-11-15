#!/bin/sh
# Removes the LaunchAgent and binary, and makes sure Battle.net isn't left paused.
set -u
launchctl bootout "gui/$(id -u)/local.bnet-sleepguard" 2>/dev/null
"$HOME/.local/bin/bnet-sleepguard" thaw 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.bnet-sleepguard.plist" "$HOME/.local/bin/bnet-sleepguard"
echo "bnet-sleepguard removed"
