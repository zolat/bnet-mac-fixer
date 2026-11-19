#!/bin/sh
# Removes the LaunchAgents and binary, and makes sure Battle.net isn't left paused.
# History (~/Library/Application Support/bnet-mac-fixer) and logs are kept.
set -u
uid="$(id -u)"
launchctl bootout "gui/$uid/local.bnet-mac-fixer.menubar" 2>/dev/null
launchctl bootout "gui/$uid/local.bnet-mac-fixer" 2>/dev/null
"$HOME/.local/bin/bnet-mac-fixer" thaw 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.bnet-mac-fixer.plist" "$HOME/Library/LaunchAgents/local.bnet-mac-fixer.menubar.plist" \
    "$HOME/.local/bin/bnet-mac-fixer" "$HOME/Library/Application Support/bnet-mac-fixer/control.sock"
# Also clean up an install from before the rename.
launchctl bootout "gui/$uid/local.bnet-sleepguard" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.bnet-sleepguard.plist" "$HOME/.local/bin/bnet-sleepguard"
echo "bnet-mac-fixer removed (history kept in ~/Library/Application Support/bnet-mac-fixer)"
