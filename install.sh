#!/bin/sh
# Builds bnet-mac-fixer and installs it as a per-user LaunchAgent.
set -eu
cd "$(dirname "$0")"

swift build -c release

uid="$(id -u)"

# Migrate from the previous name (bnet-sleepguard), so the two never run side by side.
if [ -e "$HOME/Library/LaunchAgents/local.bnet-sleepguard.plist" ] || [ -e "$HOME/.local/bin/bnet-sleepguard" ]; then
    launchctl bootout "gui/$uid/local.bnet-sleepguard" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/local.bnet-sleepguard.plist" "$HOME/.local/bin/bnet-sleepguard"
    echo "removed old bnet-sleepguard LaunchAgent (log kept at ~/Library/Logs/bnet-sleepguard.log)"
fi

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 .build/release/bnet-mac-fixer "$HOME/.local/bin/bnet-mac-fixer"

plist="$HOME/Library/LaunchAgents/local.bnet-mac-fixer.plist"
sed "s#__HOME__#$HOME#g" local.bnet-mac-fixer.plist > "$plist"

launchctl bootout "gui/$uid/local.bnet-mac-fixer" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$plist"
sleep 1
tail -n 3 "$HOME/Library/Logs/bnet-mac-fixer.log"
