# bnet-mac-fixer

Works around two Battle.net desktop app bugs on macOS, without quitting Battle.net or changing system settings:

1. **[Logged out after sleep](#1-logged-out-after-sleep)**: you close the lid with Battle.net open and come back to the password screen ("Your login session has expired", `BLZBNTBGS80000023`).
2. **[Games fail to launch right after waking](#2-games-fail-to-launch-right-after-waking)**: you open the lid, press Play, and the launch expires or the game asks you to log in.
3. **[Game updates fail until you reboot](#3-game-updates-fail-until-you-reboot)**: Update fails instantly with `BLZBNTAGT0000138F` (Agent error 5007), and a full restart is the only thing that fixes it.

It runs as a tiny per-user LaunchAgent, with an optional [menu bar icon](#menu-bar) showing what it's done. Previously named `bnet-sleepguard`.

## 1. Logged out after sleep

### The cause

It isn't the "Keep me logged in" setting, the Keychain, or your cache. It's **Power Nap / DarkWake**:

1. You close the lid. macOS sleeps, but with Power Nap on it briefly wakes in the background every few minutes ("DarkWake", typically 2–10 seconds, screen off).
2. Battle.net gets CPU time during each DarkWake, notices its connection to `us.actual.battle.net:1119` died, and reconnects.
3. Blizzard's servers respond to the reconnect with a **`token-security-checkpoint`** challenge — a small web page the client's embedded browser has to complete.
4. The Mac goes back to sleep seconds later, mid-challenge.
5. Either the server then **rejects the saved token** and the client deletes it, or the client gets stuck "submitting credentials" and gives up on the next disconnect. Both end at the password screen.

You can see it in `~/Library/Application Support/Battle.net/Logs/battle.net-*.log`:

```
E [BNLogin]         Disconnected from Battle.net: err=ERROR_NETWORK_MODULE_SOCKET_CLOSED (1016)
I [Main]            Connecting to server. address=us.actual.battle.net port=1119
I [LoginController] External Challenge URL: https://us.account.battle.net/login/challenge/…?challengeType=token-security-checkpoint
                    …Mac sleeps again before the challenge completes…
W [LoginController] Tassadar token rejected by BGS: web_auth_url
I [BNLogin]         BattleNetLogin::DeleteToken(): Clearing cached token
E [BNLogin]         Login failed. error=ERROR_TOKEN_NOT_FOUND (49)
```

…and each `Disconnected` line lines up to the second with a `DarkWake` in `pmset -g log`.

When the Mac is genuinely awake the same challenge completes silently in ~2 seconds, which is why freshly launching Battle.net always works.

### The fix

- **Pause** Battle.net (`SIGSTOP` on the app and its CEF helper processes) when macOS announces sleep. Battle.net gets a second to acknowledge the sleep notice first.
- **Keep it paused through every DarkWake.** These are detected via `IOPMrootDomain`'s `System Capabilities`, which lacks the graphics bit during maintenance wakes.
- **Resume** it (`SIGCONT`) only on a real, user-facing wake. Battle.net then reconnects once, fully awake, and any security checkpoint completes normally.

Lid-closed full wakes (e.g. a USB keyboard bump or a notification wake, which drop back to sleep within seconds) must hold for 90 seconds before Battle.net is resumed. Opening the lid resumes it immediately.

## 2. Games fail to launch right after waking

### The cause

After every wake Battle.net has to drop its old connection and sign in again. Sometimes it notices at once and is back in ~7 seconds. Often it keeps using the dead connection for **60–100 seconds** first, and launches in that window fail:

```
W [GameLaunchController] Pending game launch expired before Agent reported it running. uid=wowf
W [InstallManager]       SSO Token generation error: err=ERROR_RPC_REQUEST_TIMED_OUT (3006)
E [BNLogin]              Disconnected from Battle.net: err=ERROR_NETWORK_MODULE_SOCKET_CLOSED (1016)   ← 76 s after waking
I [BNLogin]              Logged into Battle.net successfully.                                            ← ready
```

Over two weeks of logs, every wake reconnected. The fast ones disconnected within 9 seconds; every slow one went more than 60 seconds without noticing.

### The fix

After resuming Battle.net, the fixer follows its log until it signs back in, and the menu bar shows a slim status bar across the top of the Battle.net window:

- **Reconnecting to Battle.net… Wait before pressing Play** with a timer.
- If there's no disconnect within 15 seconds, it's on the slow path: **Battle.net is stuck on its old connection. Restarting is faster.** The **Restart Battle.net** button quits it normally and relaunches it, and it signs in within ~10 seconds.
- **Battle.net is ready** for a moment, then the bar disappears.

The bar only covers its own strip, so the rest of Battle.net still works and you can ignore it or dismiss it with ✕. It stays directly above the Battle.net window (never above other apps) and hides when that window isn't on screen.

## 3. Game updates fail until you reboot

### The cause

Battle.net does installs and updates through a background process, the **Agent** (`/Users/Shared/Battle.net/Agent/Agent.<build>/Agent.app`). While a game runs, the Agent repeatedly checks the game's code signature, and **every failed check leaks a pipe**.

Some game builds fail that check every time. WoW Forever, for one, ships a data file (`icudt78l.dat`) inside `Contents/MacOS`, so `codesign --verify --strict` reports `code object is not signed at all`. Each session then leaks hundreds of descriptors. Past ~1024, the Agent's downloader can't open sockets, and every update fails instantly:

```
# /Users/Shared/Battle.net/Agent/Agent.*/Logs/AgentErrors-*.log — hundreds per game launch
Signature validation error (-67062): The operation couldn’t be completed. (OSStatus error -67062.)

# …/Logs/bc-*.log — the downloader, once descriptors run out (note: < 1 ms per attempt)
[tact] cURL request 'http://level3.blizzard.com/tpr/wow/config/…' failed with 7 : Couldn't connect to server

# …/Logs/Agent-*.log
"error": 5007, "error_message": "Failed to initialize the tact instance"
```

Rebooting fixes it only because it starts a fresh Agent.

### The fix

Every minute the fixer counts the Agent's open file descriptors (`bnet-mac-fixer status` shows the number). Once the count passes **600**, it restarts the Agent: `SIGTERM`, then `SIGKILL` if it hasn't quit within 15 seconds (it sometimes ignores `SIGTERM` mid-update). Battle.net relaunches it within seconds. It never does this while a Blizzard game is running, or within 30 seconds of one quitting. Games are recognised by the `.build.info` file at their install root, so there's no hard-coded game list. The Agent isn't restarted more than once every 5 minutes.

```
… agent: 2400 open files (limit ~1024); restart deferred until World of Warcraft, WowVoiceProxy has quit
… agent: 2740 open files (limit ~1024); stopping pid 60831
… agent: pid 60831 exited; Battle.net relaunches it on demand
```

## Install

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
git clone https://github.com/zolat/bnet-mac-fixer.git
cd bnet-mac-fixer
./install.sh
```

This builds the binary into `~/.local/bin/bnet-mac-fixer` and loads two LaunchAgents: `local.bnet-mac-fixer` (the fixer) and `local.bnet-mac-fixer.menubar` (the menu bar icon; skip it with `./install.sh --no-menubar`). If you had `bnet-sleepguard` installed, it's removed. Activity is logged to `~/Library/Logs/bnet-mac-fixer.log`:

```
… will sleep: paused 27503(main) 27508(helper) …
… powered on: caps=0xf lidClosed=true lidCausesSleep=false userAwake=true
… powered on: awake with lid closed; holding pause until …
… powered on: resumed 27508(helper) … 27503(main) [caps=0xf lidClosed=false …]
```

DarkWakes produce no log lines because nothing happens during them — that's the point.

## Menu bar

A shield in the menu bar shows what the fixer is doing and has done:

```
bnet-mac-fixer
Battle.net: running, will be paused when the Mac sleeps
Agent: 516 open files, healthy (restarts at 600)
Playing: World of Warcraft
────
Since 15 Nov
13 sleeps guarded, 3d 20h paused in total
10 background wakes held (each a possible logout)
1 Agent restart, peak 2,740 open files
Recent Activity ›
────
Restart Battle.net Agent
Open Log
About bnet-mac-fixer
────
Quit Menu Bar Icon
```

The icon changes with the state: ✓ shield when all is well, ⏸ while Battle.net is paused, ! shield when the Agent has leaked past the threshold, and a crossed-out shield if the fixer isn't running (the menu then offers to start it). **Resume Battle.net Now** appears while it's paused, and **Restart Battle.net** is always there.

The icon is a separate process that only reads from the fixer over a Unix socket. Quitting it, or a crash, doesn't affect the fixes. Quitting keeps it off until you next log in; to bring it back sooner, run `launchctl kickstart gui/$(id -u)/local.bnet-mac-fixer.menubar`.

History lives in `~/Library/Application Support/bnet-mac-fixer/activity.json`. On first run it's rebuilt from the existing logs.

## Uninstall

```sh
./uninstall.sh
```

Unloads both agents, resumes Battle.net if it's paused, and removes the binary and plists. History and logs are kept.

## Manual commands

```sh
bnet-mac-fixer status          # live state plus history: sleeps guarded, Agent restarts, recent events
bnet-mac-fixer freeze          # pause Battle.net now
bnet-mac-fixer thaw            # resume Battle.net now
bnet-mac-fixer restart-agent   # restart the Battle.net Agent now
bnet-mac-fixer restart-battlenet  # quit and relaunch Battle.net (it signs in again within seconds)
bnet-mac-fixer menubar         # run the menu bar icon (normally started by its LaunchAgent)
```

The fixer also answers JSON on its control socket, if you want to script or build your own front end:

```sh
echo '{"command":"status"}' | nc -U ~/Library/Application\ Support/bnet-mac-fixer/control.sock
# commands: status, restart-agent, resume-battlenet, restart-battlenet
```

If Battle.net ever looks frozen, `bnet-mac-fixer thaw` unsticks it. The agent also resumes Battle.net on startup if the Mac is awake, so a crashed agent can't leave it paused for long.

## Caveats

- After opening the lid Battle.net needs a few seconds to a minute and a half to sign back in (see [above](#2-games-fail-to-launch-right-after-waking)); the status bar tells you when it's ready.
- Battle.net registers for macOS sleep notifications itself and can't acknowledge them while paused, so each maintenance wake takes ~30 s longer to go back to sleep (`Battle.net timed out(30000 ms)` in `pmset -g log`). The initial sleep isn't affected: Battle.net gets a moment to acknowledge before it's paused. In testing that was ~25 extra awake-minutes over a 6-hour lid-closed sleep.
- With an external display and the lid closed (clamshell mode), Battle.net takes up to 90 seconds to resume after a wake.
- If Blizzard changes the checkpoint so it needs user interaction, this won't help.
- The "real wake" check reads undocumented-but-stable `IOPMrootDomain` registry properties (`System Capabilities`, `AppleClamshellState`, `AppleClamshellCausesSleep`).
- During one very long game session the Agent can still leak past the limit, because the fixer won't restart it while you're playing. A game update that starts mid-session may then fail; quit the game and it's fixed within a minute.

## Development

```sh
swift build -c release
swift test
```

`BnetFixerCore` holds the testable logic: wake classification, resume policy, Agent restart policy, process and game detection, the activity log and its log importer, the control socket protocol, and the menu's wording (`StatusSummary`). The `bnet-mac-fixer` executable has two halves:

- `Daemon/`: IOKit power notifications (`SleepGuard`), a one-minute timer (`AgentWatchdog`), and the control socket (`ControlService`).
- `MenuBar/`: the status item and the reconnect bar. It's a pure client of the socket. `bnet-mac-fixer overlay-preview stuck 10` shows the bar over the real Battle.net window with a fake state (`waiting`, `stuck`, `restarting`, `ready`, `timedOut`).

Not affiliated with or endorsed by Blizzard Entertainment. Battle.net is a trademark of Blizzard Entertainment, Inc.

## License

MIT
