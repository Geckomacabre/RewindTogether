---
kind: game
title: Co-op multiplayer through UE4SS Lua and a tiny native helper
game: Retro Rewind
games_also: []
game_version: Steam build 23896268 ("Changelist 2308"), UE 5.4.4 Shipping
platform: windows
engine: unreal
route: loader-api
tools:
- UE4SS 3.0.1 experimental (UE4SS_v3.0.1-944-g0196ef29)
- MSVC 14.44 (VS 2022) for one native DLL
- CUE4Parse (outside the repo) to read Blueprint bytecode
anti_cheat: none (single-player game, no online mode)
status: working
agents:
- Claude Code (claude-opus-5-5)
humans: []
date: '2026-10-14'
links:
- https://github.com/UE4SS-RE/RE-UE4SS
tags:
- multiplayer
- listen-server
- replication
- ue4ss-lua
- performance
---
# Co-op multiplayer through UE4SS Lua and a tiny native helper

Rewind Together turns Retro Rewind, a single-player UE 5.4 store sim, into listen-server co-op:
UE4SS Lua switches replication on at runtime, mirrors the state the game never meant to
share (money, clock, weather, sign, NPC looks), and replays a guest's clicks on the host. A
small native DLL, loaded from Lua with `package.loadlib`, makes the game's
"player 0" lookups answer with the guest during a replayed action. Verified with a host and
a guest on one PC, driven through a file-based dev bridge: joins, state sync, NPCs, a guest
taking a tape off a shelf and putting it back, seen on both screens.

## Setup
- Retro Rewind Steam build 23896268, Windows 11. UE4SS experimental build 0196ef29 (the
  3.0.1 release does not load on this game). Two instances on one PC: the second exe started
  directly with `SteamAppId=3552140`; the guest joins `127.0.0.1:27015` from the main menu.
- Dev bridge: the mod polls a command file only when a switch file exists next to the exe,
  runs Lua or console commands inside its own tick, and writes the result back. Every live
  measurement below went through it.

## Route and why
UE4SS Lua (loader API), plus one native DLL for the single thing Lua could not do. The
official UE4SS C++ mod template needs a private repository, so the DLL is a plain
`package.loadlib` module whose exports are lua_CFunctions built on the `RC::LuaMadeSimple::Lua`
class that UE4SS.dll exports.

## How the game works (what we had to learn)
- The main menu is `L_Boot` with `MainMenu_GameMode_C`; the store's GameMode is
  `Core_Gamemode_C`. A save is loaded by setting the GameInstance's "Save Slot" and opening
  `L_Player_Store_01`, exactly as the menu does.
- Store state lives on the GameMode (money in cents, level, XP) and on `WeatherSystem_C`
  (day, hour, season, weather). A guest has no GameMode, so it has no HUD, no clock driver,
  and the build-mode blockers (`NavCollisionZone_C`, the "yellow stripes") stay drawn.
- Blueprints find "the player" with `GetPlayerController(0)` and friends (410 of 414
  calls). On a listen server that is always the host, so a guest's replayed click acts as the
  host unless those four GameplayStatics functions are redirected.
- Movement replication: a Blueprint actor spawned at runtime copies only a precomputed list
  of properties from its class default (the ones its Blueprint changed from the native
  defaults). Patching `bReplicateMovement` on the class default does nothing for new actors,
  and it also stops Unreal from ever SENDING the flag to clients (only values that differ
  from the default are replicated). Patch actors, not defaults, and check each actor's own
  flags.

## Build steps
1. Install UE4SS 0196ef29 into `Binaries\Win64`; put the mod in `ue4ss\Mods\RewindTogether`.
2. Build the native helper with `build.bat` (finds VS via vswhere, `cl /LD /MT`).
3. The launcher (WPF, .NET 8) installs both from the release zip and writes the request
   file the mod reads to host or join.

## Verification
- Oracle: two game instances, the dev bridge, the mod's log, minidumps, screenshots.
- Lookup cost measured by wrapping `FindAllOf` / `FindFirstOf` / `StaticFindObject` in the
  live Lua state and timing every call for 10 s.
- Not verified: two real Steam accounts over Steam's relay; the till, build mode and the
  skin/mesh tools for guests.

## Gotchas
1. **Host dies when a guest joins.** **Cause:** a Lua string passed where a UFunction takes an
   FName; UE4SS dereferences it. **Fix:** always `FName("...")`. Same for TSoftObjectPtr
   parameters: build one with `MakeSoftObjectPath` → `Conv_SoftObjPathToSoftObjRef`.
2. **Random crashes in Lua's GC after 40-150 s.** **Cause:** `LoopAsync` and `RegisterKeyBind`
   callbacks run Lua on UE4SS's thread while the game thread runs the same Lua state.
   **Fix:** `LoopInGameThreadWithDelay` for the tick, keys polled with `IsInputKeyDown`.
3. **Guest crashes on an engine worker reading 0xffff...** **Cause:** loaded assets cached in a
   Lua table; a Lua reference does not keep a UObject alive, so GC freed them. **Fix:** never
   keep engine objects across frames. Remember them by path and find them again.
4. **The mod halved the frame rate.** **Cause:** UE4SS `FindAllOf` / `FindFirstOf` walk the whole
   object array: 15-17 ms a call, hit or miss; `StaticFindObject` 1-2 ms. ~40 calls a second
   was 60% of the game thread. **Fix:** ask the engine: GameInstance (one walk per process) +
   GameplayStatics for world/GameMode/controllers (microseconds); KismetSystemLibrary's
   `MakeSoftObjectPath` → `Conv_SoftObjPathToSoftObjRef` → `Conv_SoftObjectReferenceToObject`
   to resolve a loaded class or asset by path (0.02 ms; an unloaded path returns a wrapper
   around nullptr, not nil); `GetAllActorsOfClass` / `GetActorOfClass` for actors. After: 2.4%.
5. **Every actor from `GetAllActorsOfClass` fails `IsValid`.** **Cause:** out-param array
   elements are `RemoteUnrealParam` references. **Fix:** `elem:get()`. UE4SS never destroys
   the call's parameter buffer (a fixed stack array), so anything the engine allocates for a
   parameter or return value leaks: 8 bytes per element of an out array, and about 0.6 KB per
   soft-path lookup (the path string becomes an FString; 100,000 calls: +124 MB, a
   struct-free control +19 MB). The references stay readable. Memoize lookups per tick, keep
   native classes (they never unload), and list big classes every few seconds only.
   Worse, UE4SS takes a Lua registry reference to every out-param table and never releases
   it: the table and its wrappers live forever (registry +4 entries/s here). After the call,
   find the registry entry whose value is your table (`debug.getregistry()`, identity
   compare) and set it to nil.
6. **Guest sees moved objects frozen.** **Cause:** gotcha in "How the game works":
   `bReplicateMovement` false on the guest's copies, so `OnRep_ReplicatedMovement` ignored
   every update. **Fix:** never patch that flag on a class default; patch actors on the host,
   continuously; on the guest, set it where it is still off and call
   `OnRep_ReplicatedMovement` (only if a non-zero position was received and nothing holds it).
7. **Out-params followed by more params cannot be called; struct fields come back in the
   FName table's casing** (`FRotator.pitch`). Read struct fields case-insensitively.
8. **A replayed guest click acts as the host.** **Cause:** player-0 lookups. **Fix:** the DLL
   swaps `UFunction::Func` (at +0xD8 on this build, found by scanning for the first pointer
   into the exe's code section) of the four GameplayStatics getters for thunks that call the
   original and substitute host→guest results while a window is open. It pins itself, because
   Lua frees loaded libraries on mod reload.
9. **Two `FindAllOf` results for one actor compare unequal.** UE4SS hands out a new wrapper
   per lookup: compare full names or addresses, never `==`.

## Assets
None generated. NPC looks are the game's own meshes and materials, applied by path.

## Cost and time
Several long sessions; most of the time went into crashes (gotchas 1-3) and the
replication facts (gotcha 6).

## Open questions
- The guest HUD lacks the item-in-hand and look-at panels: the plan is to make Blueprint
  `GetGameMode` (null on a guest) answer with the guest's HUD widget, natively.
- A real two-account test of the launcher's Steam relay tunnel.
