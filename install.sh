#!/bin/sh
# Builds bnet-mac-fixer and installs it as per-user LaunchAgents: the fixer itself, plus the
# optional menu bar icon (skip it with ./install.sh --no-menubar).
set -eu
cd "$(dirname "$0")"

menubar=1
[ "${1:-}" = "--no-menubar" ] && menubar=0

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

load() { # label
    plist="$HOME/Library/LaunchAgents/$1.plist"
    sed "s#__HOME__#$HOME#g" "$1.plist" > "$plist"
    launchctl bootout "gui/$uid/$1" 2>/dev/null || true
    # bootout returns before the old job has fully unloaded; retry until launchd accepts it.
    for _ in 1 2 3 4 5; do
        launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null && return 0
        sleep 1
    done
    launchctl bootstrap "gui/$uid" "$plist"
}

load local.bnet-mac-fixer
if [ "$menubar" = 1 ]; then
    load local.bnet-mac-fixer.menubar
else
    launchctl bootout "gui/$uid/local.bnet-mac-fixer.menubar" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/local.bnet-mac-fixer.menubar.plist"
fi
sleep 1
tail -n 3 "$HOME/Library/Logs/bnet-mac-fixer.log"
