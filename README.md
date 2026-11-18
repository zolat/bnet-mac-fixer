# bnet-mac-fixer

Works around two Battle.net desktop app bugs on macOS, without quitting Battle.net or changing system settings:

1. **[Logged out after sleep](#1-logged-out-after-sleep)**: you close the lid with Battle.net open and come back to the password screen ("Your login session has expired", `BLZBNTBGS80000023`).
2. **[Game updates fail until you reboot](#2-game-updates-fail-until-you-reboot)**: Update fails instantly with `BLZBNTAGT0000138F` (Agent error 5007), and a full restart is the only thing that fixes it.

It runs as a tiny per-user LaunchAgent. Previously named `bnet-sleepguard`.

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

## 2. Game updates fail until you reboot

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

Every minute the fixer counts the Agent's open file descriptors (`bnet-mac-fixer status` shows the number). Once the count passes **600**, it restarts the Agent with `SIGTERM`, and Battle.net relaunches it within seconds. It never does this while a Blizzard game is running, or within 30 seconds of one quitting. Games are recognised by the `.build.info` file at their install root, so there's no hard-coded game list. The Agent isn't restarted more than once every 5 minutes.

```
… agent: 2400 open files (limit ~1024); restart deferred until World of Warcraft, WowVoiceProxy has quit
… agent: 2400 open files (limit ~1024); restarted pid 60831
```

## Install

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
git clone https://github.com/zolat/bnet-mac-fixer.git
cd bnet-mac-fixer
./install.sh
```

This builds the binary into `~/.local/bin/bnet-mac-fixer` and loads `~/Library/LaunchAgents/local.bnet-mac-fixer.plist`. If you had `bnet-sleepguard` installed, it's removed. Activity is logged to `~/Library/Logs/bnet-mac-fixer.log`:

```
… will sleep: paused 27503(main) 27508(helper) …
… powered on: caps=0xf lidClosed=true lidCausesSleep=false userAwake=true
… powered on: awake with lid closed; holding pause until …
… powered on: resumed 27508(helper) … 27503(main) [caps=0xf lidClosed=false …]
```

DarkWakes produce no log lines because nothing happens during them — that's the point.

## Uninstall

```sh
./uninstall.sh
```

Unloads the agent, resumes Battle.net if it's paused, and removes the binary and plist.

## Manual commands

```sh
bnet-mac-fixer status          # power state, Battle.net PIDs, Agent open files, running games
bnet-mac-fixer freeze          # pause Battle.net now
bnet-mac-fixer thaw            # resume Battle.net now
bnet-mac-fixer restart-agent   # restart the Battle.net Agent now
```

If Battle.net ever looks frozen, `bnet-mac-fixer thaw` unsticks it. The agent also resumes Battle.net on startup if the Mac is awake, so a crashed agent can't leave it paused for long.

## Caveats

- After opening the lid Battle.net shows "offline" for ~3–5 seconds while it reconnects. After a long sleep (hours), its old connection is silently dead and it can take a minute or so to notice. During that time a game launch may stall or skip the SSO token, and then it reconnects and signs in normally.
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

`BnetFixerCore` holds the testable logic: wake classification, resume policy, Agent restart policy, process and game detection. The `bnet-mac-fixer` executable wires it to IOKit power notifications (`SleepGuard`) and a one-minute timer (`AgentWatchdog`).

Not affiliated with or endorsed by Blizzard Entertainment. Battle.net is a trademark of Blizzard Entertainment, Inc.

## License

MIT
