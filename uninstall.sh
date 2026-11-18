#!/bin/sh
# Removes the LaunchAgent and binary, and makes sure Battle.net isn't left paused.
set -u
uid="$(id -u)"
launchctl bootout "gui/$uid/local.bnet-mac-fixer" 2>/dev/null
"$HOME/.local/bin/bnet-mac-fixer" thaw 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.bnet-mac-fixer.plist" "$HOME/.local/bin/bnet-mac-fixer"
# Also clean up an install from before the rename.
launchctl bootout "gui/$uid/local.bnet-sleepguard" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.bnet-sleepguard.plist" "$HOME/.local/bin/bnet-sleepguard"
echo "bnet-mac-fixer removed"
