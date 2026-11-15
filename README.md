# bnet-sleepguard

Stops the Battle.net desktop app on macOS from logging you out every time your Mac sleeps — without quitting it.

If you've ever closed your MacBook lid with Battle.net open and come back to the password screen ("Your login session has expired", `BLZBNTBGS80000023`), this is probably why, and this fixes it.

## The cause

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

## The fix

`bnet-sleepguard` is a tiny per-user LaunchAgent that:

- **pauses** Battle.net (`SIGSTOP` on the app and its CEF helper processes) the instant macOS announces sleep;
- **keeps it paused through every DarkWake** — these are detected via `IOPMrootDomain`'s `System Capabilities`, which lacks the graphics bit during maintenance wakes;
- **resumes** it (`SIGCONT`) only on a real, user-facing wake. Battle.net then reconnects once, fully awake, and any security checkpoint completes normally.

Lid-closed full wakes (e.g. a USB keyboard bump or a notification wake, which drop back to sleep within seconds) must hold for 90 seconds before Battle.net is resumed. Opening the lid resumes it immediately.

Nothing is quit, no power settings are changed, and the Battle.net Agent and your games are never touched.

## Install

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
git clone https://github.com/zolat/bnet-sleepguard.git
cd bnet-sleepguard
./install.sh
```

This builds the binary into `~/.local/bin/bnet-sleepguard` and loads `~/Library/LaunchAgents/local.bnet-sleepguard.plist`. Activity is logged to `~/Library/Logs/bnet-sleepguard.log`:

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
bnet-sleepguard status   # current power state + Battle.net PIDs
bnet-sleepguard freeze   # pause Battle.net now
bnet-sleepguard thaw     # resume Battle.net now
```

If Battle.net ever looks frozen, `bnet-sleepguard thaw` unsticks it. The agent also resumes Battle.net on startup if the Mac is awake, so a crashed agent can't leave it paused for long.

## Caveats

- After opening the lid Battle.net shows "offline" for ~3–5 seconds while it reconnects. After a long sleep (hours), its old connection is silently dead and it can take a minute or so to notice. During that time a game launch may stall or skip the SSO token, and then it reconnects and signs in normally.
- Battle.net registers for macOS sleep notifications itself and can't acknowledge them while paused, so each maintenance wake takes ~30 s longer to go back to sleep (`Battle.net timed out(30000 ms)` in `pmset -g log`). The initial sleep isn't affected: Battle.net gets a moment to acknowledge before it's paused. In testing that was ~25 extra awake-minutes over a 6-hour lid-closed sleep.
- With an external display and the lid closed (clamshell mode), Battle.net takes up to 90 seconds to resume after a wake.
- If Blizzard changes the checkpoint so it needs user interaction, this won't help.
- The "real wake" check reads undocumented-but-stable `IOPMrootDomain` registry properties (`System Capabilities`, `AppleClamshellState`, `AppleClamshellCausesSleep`).

## Development

```sh
swift build -c release
swift test
```

`SleepGuardCore` holds the testable logic (wake classification, resume policy, process matching); the `bnet-sleepguard` executable wires it to IOKit power notifications.

Not affiliated with or endorsed by Blizzard Entertainment. Battle.net is a trademark of Blizzard Entertainment, Inc.

## License

MIT
