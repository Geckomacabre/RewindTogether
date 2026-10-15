# Launcher <-> mod contract

The launcher (`launcher/`, C#) and the in-game mod (`Mods/RewindTogether/Scripts`, Lua under
UE4SS) never talk directly. They exchange small JSON files in the game's working directory,
`<game>\RetroRewind\Binaries\Win64\` (written `WIN64` below) — the directory UE4SS runs the
Lua mod in, so the mod reads and writes them with plain relative paths.

All files are UTF-8, no BOM, written atomically (write `<name>.tmp`, then rename over).

## 1. `WIN64\RewindTogether.launch.json` — launcher -> mod (a one-shot request)

Written by the launcher just before it starts the game (or while the game is already at its
main menu). The mod polls for it every tick while it is NOT in a session, acts on it once,
and deletes it. Ignored (and deleted) if `written` is more than 600 seconds old.

```json
{ "action": "join", "address": "127.0.0.1:27016", "host_name": "Alex", "written": 1760467200 }
{ "action": "host", "written": 1760467200 }
```

- `join`: the mod connects to `address` as soon as the game has a PlayerController — at the
  main menu is fine; **no save needs loading** (verified in 1.7.0: OpenLevel from the menu
  joins in ~2 s). `address` is `ip:port` or `ip` (port 27015 implied). For a Steam-relay join
  the launcher's tunnel listens on `127.0.0.1:<port>` and the address points there.
- `host`: the mod waits until the player has loaded a save and is standing in their store,
  then opens it to friends (the same as pressing F7). The player still picks their save,
  unless the request names one:

  ```json
  { "action": "host", "slot": "Player_Save1", "written": 1760467200 }
  ```

  `slot` is `Player_Save1` … `Player_Save5` (the five slots on the game's save screen, top
  to bottom). The mod loads it from the main menu the way the game's own menu does
  (`GameInstance."Save Slot"`, then `OpenLevel L_Player_Store_01`; an empty slot starts a
  new game in it), then hosts. Anything else in `slot` makes the request invalid.

## 2. `WIN64\RewindTogether.status.json` — mod -> launcher (heartbeat)

Rewritten by the mod every 2 seconds while the game runs.

```json
{
  "version": "1.7.0",
  "mode": "Standalone",          // Standalone | ListenServer | Client
  "in_store": true,              // a player pawn exists in a real level
  "players": 1,                  // connected player controllers, host included
  "port": 27015,                 // the port a host listens on
  "last_error": "",              // short, human sentence, or ""
  "updated": 1760467200          // unix seconds; stale after 6 s = game not running
}
```

## 3. `WIN64\ue4ss\Mods\RewindTogether\mod.json` — shipped with the mod

```json
{ "id": "rewind-together", "name": "Rewind Together", "version": "1.7.0",
  "game_build": "23896268", "ue4ss": "3.0.1" }
```

`game_build` is the Steam `buildid` the mod was tested on (the main menu shows it as "Changelist 2308"). The launcher compares it with
`buildid` in `steamapps\appmanifest_3552140.acf` and warns (does not block) on a mismatch.

## 4. Ports

- A host's listen server is UDP **27015** on this build (from the packaged DefaultEngine.ini;
  `?Port=` does not move it). Measured, see PROJECT.md §5.
- The guest-side tunnel listens on `127.0.0.1:27016` by default (27015 may be in use if the
  same machine ever hosts), so a launcher join writes `"address": "127.0.0.1:27016"`.

## 5. Steam rich presence (launcher-owned)

While hosting, the launcher sets rich presence on the Retro Rewind app:
`rt_host = "1"`, `connect = "+rt_join <host SteamID64>"`. A friend's launcher lists friends
whose `rt_host` is `"1"`. If a friend uses Steam's own "Join Game", Steam starts the GAME with
`+rt_join <id>` on its command line; the mod then starts the launcher with
`--join <id>` (path read from `WIN64\RewindTogether.launcher.txt`, which the launcher writes
on every start) and waits for a `launch.json` from it.
