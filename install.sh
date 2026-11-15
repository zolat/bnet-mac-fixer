#!/bin/sh
# Builds bnet-sleepguard and installs it as a per-user LaunchAgent.
set -eu
cd "$(dirname "$0")"

swift build -c release

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 .build/release/bnet-sleepguard "$HOME/.local/bin/bnet-sleepguard"

plist="$HOME/Library/LaunchAgents/local.bnet-sleepguard.plist"
sed "s#__HOME__#$HOME#g" local.bnet-sleepguard.plist > "$plist"

launchctl bootout "gui/$(id -u)/local.bnet-sleepguard" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
sleep 1
tail -n 3 "$HOME/Library/Logs/bnet-sleepguard.log"
