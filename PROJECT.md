# Rewind Together — project brief

Written for a person or an AI picking this up cold. Read this before changing
anything; most of what looks like an obvious improvement here has already been
tried and has a reason for being the way it is.

---

## 0. 1.7.0 — read this first

Sections 1–10 below are the 1.6.1 brief, kept because their reasoning still holds. Where
they disagree with this section, **this section wins**: everything here was measured with a
host and a guest running on one PC. MODLOG.md is the session journal; VERSION.txt says what
each bug actually was.

### How to test now (one PC, no friend needed)

- `py dev/coop_test.py up` starts a host (through Steam, loads save 1 with no clicks) and a
  guest (the Shipping exe started directly with `SteamAppId=3552140`), and joins the guest to
  `127.0.0.1` from its main menu. `down` kills both by PID; `log` shows the session.
- Both are driven through **`devbridge.lua`**, which does nothing unless
  `Binaries\Win64\RewindTogether.devbridge` exists. `py dev/bridge.py A rt.status` or
  `py dev/bridge.py B "lua return ..."`. Slot A = first instance, B = second. Each slot also
  writes `RewindTogether.trace.<slot>`: the last tick phase that started, which is how a
  native crash gets pinned to a phase.
- Release: `py dev/package.py` stages and zips `dist/RewindTogether-<version>.zip` (launcher exe,
  the mod with its native DLL, README/FRIEND/VERSION, the two port tools, the DLL's source) after
  checking that mod.json, net.lua and VERSION.txt agree. Then `um publish check` it against the
  game's `Content` and `Engine` folders (against the whole install it flags our own deployed copy).
- After a test session: restore `GameUserSettings.ini` from `GameUserSettings.ini.pre-claude` and
  delete `RewindTogether.devbridge`, `RewindTogether.bridge.*` and `RewindTogether.trace.*`.
- Crash reports: `%LOCALAPPDATA%\RetroRewind\Saved\Crashes\`. Read the minidump's thread
  name (ThreadNamesStream) before theorising: GameThread vs a "Foreground Worker" changes
  everything.
- The game's classes: `%USERPROFILE%\RetroRewind-decomp\CXXHeaderDump` (UE4SS GenerateSDK,
  with offsets). Its Blueprint logic as pseudo-code: `...\RetroRewind-decomp\bp\*.txt` and
  `FINDINGS.md` (CUE4Parse tool in `...\bpdump`). Outside the repo on purpose; never ship.

### Facts that replace earlier beliefs

- **The main menu is `L_Boot` with `MainMenu_GameMode_C`,** not the store level. Tell menu
  from store by the GameMode class (`Core_Gamemode_C` = in a store). `GetCurrentLevelName`
  still does not resolve; `Net.getCurrentMapName()` returns a hard-coded fallback.
- **Joining from the main menu works** (OpenLevel → client in ~2 s). No save needed.
- **Loading a save without clicks:** `GameInstance."Save Slot" = "Player_Save<N>"`, then
  `OpenLevel("L_Player_Store_01")`. That's exactly what the game's menu does.
- **The yellow hazard stripes** are `NavCollisionZone_C` ghost-mode blockers that the host's
  GameMode hides at load; a guest has no GameMode (worldsync.lua hides them).
- **Store state lives in** `Core_Gamemode_C` (Money int64 cents, Level, Experience, …) and
  `WeatherSystem_C` (Day/Hour/Minute/Season/…). The old `SyncedState` names never existed.
- **The game's Blueprints find "the player" with `GetPlayerController/Character/Pawn(0)`**
  (410 of 414 calls). Hand and inventory code works on `Self`. There are no Blueprint RPCs
  and no locally-controlled checks.
- **Every HUD call goes to the GameMode's single widget** (the host's).

### UE4SS 3.0.1 (this build) gotchas: each one was a crash or a silent refusal

- A Lua string passed for an **FName** parameter → native crash. Use `FName("x")`.
- A Lua string passed for a **TSoftObjectPtr** parameter → native crash. Build one with
  KismetSystemLibrary `MakeSoftObjectPath` → `Conv_SoftObjPathToSoftObjRef`.
- **Out-parameters followed by more parameters** can't be called (the table is never
  consumed). Struct out-params like `FHitResult` with `{}` do work.
- **Struct fields come back in the FName table's casing** (`FRotator.pitch`). Use
  `UE.field` / `UE.rot` / `UE.vec`.
- **LoopAsync and RegisterKeyBind run Lua off the game thread.** The tick uses
  `LoopInGameThreadWithDelay`, and keys are polled with `IsInputKeyDown`.
- **Nothing from an RPC hook is applied inside the hook.** Hooks queue; `Chan.pump()` applies.
- **Never keep engine objects in Lua across frames, including assets:** GC frees them. That
  caused the NPC-look crashes. Remember an object by PATH (`UE.pathOf`) and find it again with
  `UE.findObject` (0.03 ms). The only objects kept are the GameInstance, the engine and the
  library default objects, which live as long as the process.
- **FindAllOf / FindFirstOf walk every object: 15-17 ms a call, hit or miss.** StaticFindObject
  is 1-2 ms. Use `UE.findAll` / `UE.findFirst` (GetAllActorsOfClass / GetActorOfClass through
  a class resolved by path, 0.02 ms) and `UE.findObject` (KismetSystemLibrary soft-reference
  route). The mod spent 60% of the host's game thread in walks before this.
- **Out-param arrays come back as RemoteUnrealParam elements:** call `:get()` on each. UE4SS
  never destroys the call's parameter buffer (`DynamicUnrealFunctionData`, a stack array), so
  whatever the engine allocates for a parameter or return value leaks: 8 bytes per element of
  an out array, ~0.6 KB per `UE.findObject` (its path becomes an FString). Readable
  afterwards, but list big classes every few seconds and look each path up once per tick.
- **Every out-param table is kept forever:** UE4SS takes a Lua registry reference to it
  (`make_ref`) and never releases it, so the table and all its wrappers never get collected.
  Measured: the registry grew ~4 entries/s. Call `UE.releaseOut(t)` after the call, or wrap
  FHitResult calls in `UE.withHit(function(hit) ... end)`.
- **A class default does not reach a spawned Blueprint actor** except for the properties its
  Blueprint changed from the native defaults (measured: bReplicates yes, bReplicateMovement no).
  And a property patched on a class default is never SENT: Unreal only replicates values that
  differ from the default. Patch actors, check their own flags.

### New modules

| Module | Responsibility |
|---|---|
| `devbridge.lua` | Dev-only file command bridge + phase trace (inert without its switch file) |
| `input.lua` | Keys polled on the game thread |
| `hud.lua` | Builds the game's own HUD on a guest and feeds it the host's numbers |
| `worldsync.lua` | Sign, expansions, season level, sky/lights/fog/collection values, stripes |
| `npcsync.lua` | NPC looks (body, clothes, tints, hair) + AnimBP inputs, matched by position |
| `guestinput.lua` | Guest presses (RMB/LMB/E/V/B/K) replayed on the guest's pawn on the host |
| `native.lua` + `native\RewindNative\` | `RewindNative.dll`: the player-0 redirect (see below) |
| `launchfile.lua` | The launcher contract: `launch.json` in, `status.json` out |

### The native helper

`native\RewindNative\RewindNative.cpp`, built with `build.bat` (MSVC; VS 2022 Community has
it). It is **not** a UE4SS C++ mod, because that SDK needs the private UEPseudo repo. Lua loads
it with `package.loadlib`. Its exports are lua_CFunctions that read and return values through
`RC::LuaMadeSimple::Lua`, which UE4SS exports. It swaps `UFunction::Func` (+0xD8 on this
build) on the four GameplayStatics player getters. Inside `Native.asPlayer(guestPC, fn)` they
answer with the guest. The DLL pins itself (Lua frees libraries on hot reload).

### The launcher

`launcher\` (C# WPF, .NET 8): it detects the game, installs UE4SS and the mod, and has a mod
manager, host/join, a Steam-relay tunnel and a friends list. Its contract with the mod is
`docs\LAUNCHER_CONTRACT.md`. The Steam parts can't be tested on one PC with one account.

### Still open

- The guest HUD doesn't show product-in-hand or look-at details. The fix that's ready to
  build: on a guest, make Blueprint `GetGameMode` (null there) answer with the guest's HUD
  widget. Every Blueprint use of that result is `Cast<Core_Gamemode_C>` (fails safely) or
  `ToInterface<UI_Interface_C>` (the widget implements it); checked across all Blueprints.
  It needs a native "replace null" mode and clearing on map load.
- Verified since: guest put-back (LMB while holding) shows on both screens.
- Not yet verified: the till/checkout, build mode, skin/mesh tools, end of day while a guest
  is connected, and a real two-account Steam relay.

---

## 1. What this is

**Rewind Together** is a co-op multiplayer mod for **Retro Rewind** (Steam
AppID 3552140), a single-player video-store management game built on **Unreal
Engine 5.4**, shipped as a **Shipping** build (no editor, no dev console, most
debug paths compiled out).

The mod is written in **Lua** and runs under **UE4SS 3.0.1**. There is no C++,
no DLL of our own, and no modification of the game's `.pak` files. Everything
happens at runtime through UE4SS's reflection bridge.

It is intended for public release on Nexus Mods as the first multiplayer mod
for this game. **Read §9 before making design decisions** — it defines the
target and the rules that follow from it, and several things that would be
reasonable in a two-person tool are disqualifying in a shipped one.

The core idea: the shipped binary already contains the entire Unreal
multiplayer stack — `OnlineSubsystemSteamCore`, `IpNetDriver`, and a player
pawn deriving from `ACharacter` (so client prediction and server reconciliation
already exist). The game simply never opens a session. So the mod:

1. travels the host into a **listen server on their own save** (`?listen`),
2. flips `bReplicates` on for the actor classes that matter,
3. mirrors the store simulation — money, day counter, chat — over a **Steam P2P
   side-channel** the mod owns, because none of the shop Blueprints were
   authored to replicate,
4. gives arriving players a pawn, because the game's single-player GameMode
   does not.

---

## 2. Where the files are

There are **two copies of the mod** and they must be kept in sync.

| | Path |
|---|---|
| **Source of truth** (edit here) | `D:\SteamLibrary\steamapps\common\RetroRewind\RewindTogether\Mods\RewindTogether\Scripts\` |
| **Deployed** (what the game loads) | `D:\SteamLibrary\steamapps\common\RetroRewind\RetroRewind\Binaries\Win64\ue4ss\Mods\RewindTogether\Scripts\` |

`Install-RewindTogether.ps1` deploys by deleting the target folder and
recursive-copying the source over it. During development it is quicker to copy
the changed `.lua` files directly — but **always copy**, or you will spend an
hour debugging a fix the game never loaded.

Other things in the project root:

| File | What it does |
|---|---|
| `Install-RewindTogether.ps1` | Full installer: UE4SS check, mod deploy, `mods.txt` wiring, transport profile. Preserves a user-edited `config.lua` when `Config.ConfigVersion` matches. |
| `Uninstall-RewindTogether.ps1` | Reverses it. |
| `Enable-DirectHosting.ps1` | Firewall rule + UPnP port forward for UDP 27015, prints the public IP. Driven by `OPEN PORT FOR FRIENDS.bat`. |
| `Check-Connection.ps1` | Reads the game's **real** listening socket. This is the authority on what port is actually in use — see §5. |
| `Test-Inbound.ps1` | Confirms UDP 27015 is reachable from outside. |
| `Check-Mod.py` | Parses *and runs* both copies against a fake UE4SS. Run before every deploy — see §7. |
| `test\` | The fake engine and the smoke test `Check-Mod.py` drives. |
| `tunnel\RewindTunnel.exe` | Standalone Steam-relay UDP tunnel, used when port forwarding is not an option. Host and guest each run their own; the peer SteamID is hardcoded in the `START TUNNEL` batch files, one per side. |
| `config\Engine.DirectIP.ini`, `config\Engine.SteamP2P.ini` | Transport profiles the installer copies in. Largely vestigial — see §5, the game wipes user `Engine.ini` on launch. |
| `VERSION.txt` | Changelog, written as "what the bug actually was". Worth reading in full. |
| `README.md` | User-facing docs. |
| `FRIEND - START HERE.txt` | Guest-side setup instructions. |

Logs, after a run:

- `...\Binaries\Win64\ue4ss\UE4SS.log` — everything, including our lines
  prefixed `[Lua] [RewindTogether]`.
- `...\Binaries\Win64\RewindTogether.log` — our lines only (`Config.LogToFile`).

---

## 3. Module map

All under `Mods/RewindTogether/Scripts/`. Load order is enforced by `require`
in `main.lua`: config → log → engine helpers → transport → features → commands.

| Module | Responsibility |
|---|---|
| `main.lua` | Entry point. Owns the 10 Hz tick loop, engine hooks, session lifecycle. |
| `config.lua` | All user-editable settings. `Config.ConfigVersion` gates whether the installer preserves it. |
| `log.lua` | Levelled logging + `Log.guard()`, which every hook and timer goes through (UE4SS silently stops running a Lua callback that throws). |
| `ue.lua` | **The only file that reaches into the engine.** Object accessors, per-frame cache, net-mode detection, reflection helpers, SteamID extraction. |
| `net.lua` | Hosting, joining, transport selection, the self-test, all the diagnostics that print those big `=====` blocks. |
| `replication.lua` | Turns `bReplicates` on, via class default objects. |
| `spawn.lua` | Gives a joining player a pawn when the GameMode won't, and puts them somewhere real once they have one. |
| `inspect.lua` | Runtime property dumper behind `rt.state` / `rt.props` / `rt.why`. Exists so property names are read off the running game instead of guessed. |
| `players.lua` | Player roster and (disabled in SafeMode) nametags. |
| `sync.lua` | Host-authoritative mirroring of store state, and guest interaction forwarding. |
| `rpcchan.lua` | **The side-channel that works.** Rides the game's own `UNetConnection`: `ClientMessage` down, `ServerSetSpectatorLocation` up. No Steam, no ports, no config. |
| `localgm.lua` | Builds a GameMode on a guest, who otherwise has none — and strips the build-mode overlay. |
| `steamp2p.lua` | The Steam P2P side-channel. **Cannot work on this build** (§5); kept only as a fallback that never fires. |
| `steamjoin.lua` | Steam presence, invites, `+connect` command line. |
| `chat.lua` | Chat over the P2P channel, host-relayed. |
| `overlay.lua` | On-screen text via `TextRenderComponent`. Disabled by `SafeMode`. |
| `mainmenu.lua` | "PLAY CO-OP" menu entry. **Off by default — it crashes this build.** |
| `bodies.lua` | Gives other players a visible body borrowed from an NPC. Purely local — needs no authority and no agreement with the other side. |
| `safety.lua` | Crash breadcrumbs (a feature that crashes gets switched off, once) and config validation. |
| `commands.lua` | `rt.*` console commands and keybinds. |

---

## 4. Current status

**Works, verified from logs on real hardware:**

- Hosting. `F7` in-store travels to a listen server on UDP 27015.
- Joining by IP. The guest connects; the host logs `a player joined (2 connected)`.
- Replication of ~730 actors across 26 classes.
- The Steam P2P side-channel binds and the local SteamID resolves.

- A guest arriving with a working character, standing next to the host. Two
  live two-machine tests, measured — see §6.

- **Players can see each other.** Confirmed from screenshots of both machines
  in one session: each sees the other as a body borrowed from a town NPC. That
  settles the two-candidate question below — the remote `Player_Character_C`
  **does** replicate, and the only cause was ever the missing third-person
  mesh. `bodies.lua` is the answer to it.

**Broken, with the cause known:**

- **The borrowed body floated, and the cause was the engine.** Fixed in 1.5.9;
  kept here because the way it was missed is worth more than the fix.

  A remote player is a **simulated proxy**, and `ACharacter` network-smooths
  those. `SmoothClientPosition_UpdateVisuals()` writes the mesh's relative
  transform *every frame* from `CharacterOwner->GetBaseTranslationOffset()`,
  which `ACharacter` caches at construction from wherever the mesh sat.
  `Player_Character_C` has never had a body in it, so that cache is `(0,0,0)`
  — which is exactly the value the offset kept reverting to.

  Write `BaseTranslationOffset` / `BaseRotationOffset` (both `UPROPERTY()`;
  `CacheInitialMeshOffset` is plain C++ and unreachable). Smoothing then
  produces the right offset itself and the body interpolates properly.

  **Three versions fixed the write instead of finding the writer.** The
  measurement that settled it — apply, verify, re-read nine seconds later —
  existed a version before it was acted on. When a value goes back on its own,
  the write is not the bug.
- **Props render as yellow placeholder boxes on the guest.** 1.5.7 found the
  cause and it was the mod: patching `bReplicates` onto class default objects
  **on the guest** tells every level-placed actor of that class it is a network
  proxy awaiting server data, so it never runs its own setup and draws its bare
  default. Patching is server-only now. The guest's latest screenshots show far
  less of it but not none — **check both machines are on the same mod version
  before reading anything into what is left.**
- **Money, day, season, time do not sync.** Two causes stacked, and the second
  was hidden behind the first. 1.5.0 found that `Net.addPeer` had zero callers,
  so the peer list was always empty and `Sync.tickHost` returned on its first
  line. That was real and is fixed. It was not sufficient: the next run, with
  the peer's ID configured and a guest connected for five minutes, still logged
  no `hello`, no `accepted P2P session` and no registered peer. **Every send
  was failing on SteamID marshalling** — the mod carries IDs as strings
  (it must; a SteamID64 is past 2^53), SteamCore Pro wants an `FSteamID`
  struct, and the throw was reported only at `debug`. Fixed in 1.5.1 by
  probing the argument shape and keeping what works. **The channel has still
  never been observed carrying a packet** — `rt.status` now counts traffic, so
  the next run settles it. Until it does, the property names in
  `Config.SyncedState` remain unverified; `rt.state` on both machines is how to
  confirm them.

- **The spawn ladder crashed the game once, and the cause is now known.**
  A guest who is *leaving* looks exactly like a guest who needs a pawn — theirs
  has just been unpossessed and is standing in the store — and their
  `PlayerController` survives in `FindAllOf` for a while after the connection
  is cleaned up. The ladder called `HandleStartingNewPlayer` on one and the
  process was gone twelve seconds later with nothing logged. `spawn.lua`'s
  `isLiveGuest` is the guard; see §6.

**Known not to work on this build:**

- Steam relay transport / joining by Steam ID (§5).
- The main-menu button (`Config.ShowMainMenuButton`, crashes at the boot menu).
  Still off by default, but a crash now retires it rather than repeating.
- Nametags and the in-game overlay. `Config.SafeMode` is back **on** after
  1.5.1 turned it off on a theory that was measured and disproved — see §10.
  Runtime component construction returns an object that passes
  `UObject::IsValid` and then reports a null instance on the first method call.

---

## 5. Established facts — do not re-derive these

Each of these cost real time. They are stated as facts because they were
measured on this build, not reasoned about.

**The Steam relay net driver never starts.**
`SteamCoreSocketsNetDriver` is present and loadable, but the engine calls
`IsAvailable()` on it, gets false, and **silently substitutes
`DriverClassNameFallback`** — so every "steam" host actually comes up on
`IpNetDriver`. A `steam.<id>` address means nothing to `IpNetDriver`, so the
guest is bounced to the main menu with nothing logged anywhere. This is why
`Config.Transport` defaults to `"ip"` and why joining by Steam ID is now
*refused with an explanation* rather than half-attempted.

**The game wipes user `Engine.ini` on launch.**
Only `GameUserSettings.ini` survives. Dropping `NetDriverDefinitions` into
`Saved\Config\Windows\Engine.ini` achieves nothing. The mod instead rewrites
`UEngine::NetDriverDefinitions` **in memory** immediately before travelling,
then reads it back to verify — because UE4SS can hand back a *copy* of a
struct array element, in which case the assignment is silently discarded, and
that failure looks identical to the driver refusing to start.

**The listen port is 27015, not 7777.**
It comes from the packaged `DefaultEngine.ini` inside the `.pak`, which nothing
can wipe. `?Port=` on a travel URL does **not** move it — `FURL` reads the port
from the `host:port` part of an address, not from an option. A previous version
"fixed" this to 7777 on theory and broke a setting that was correct all along.
`Check-Connection.ps1` reads the real socket; it outranks any reasoning.

**`APlayerController::ClientTravel` is not reflected.**
Only `ClientTravelInternal` carries `UFUNCTION` data. Calling `ClientTravel`
through UE4SS throws. Travel goes through `UGameplayStatics::OpenLevel` first —
it is `BlueprintCallable`, so it is guaranteed present in Shipping, and it is
the same call already proven to travel the host into a listen server.

**`ConsoleCommand("open ...")` dispatches successfully and does nothing.**
Travel exec commands are compiled out of Shipping builds, but dispatching one
does not report failure. This made a total no-op look like a successful join
for a long time. Hence the rule below.

**The engine's own RPCs are the side-channel. Do not build another one.**
SteamCore Pro's P2P cannot work here (`FSteamID` wraps a `uint64`, UE cannot
make that a `UPROPERTY`, the struct has zero reflected fields, 22 shapes
refused). But `APlayerController::ClientMessage` is `UFUNCTION(Reliable,
Client)` and carries an arbitrary `FString` host→guest, and
`ServerSetSpectatorLocation` is `UFUNCTION(unreliable, server)` and carries six
floats guest→host. Both are stock Engine, both are reflected, both are hookable
because RPCs carry reflection data by definition, and the connection they ride
has existed since the guest joined. `rpcchan.lua`. It took five versions to
notice, which is the real lesson: the mod spent them trying to build a
transport next to one that was already open.

**Anything that "issues" an action gets a watchdog.**
Hosting, joining and pawn provisioning all check a few seconds later whether
the thing they asked for actually happened, and say so loudly if not. A silent
no-op that reports success is the worst possible failure mode and this project
has been bitten by it more than once.

**`AGameModeBase::PostLogin` and `::Logout` cannot be hooked.**
They are plain C++ virtuals with no `UFUNCTION`, so they carry no reflection
data. The `K2_` variants and `HandleStartingNewPlayer` *are* reflected and are
hooked instead; join/leave detection also has a polling fallback in `tick()`.

**UE4SS's built-in `UObject` members shadow reflected UFunctions of the same
name.** `IsValid`, `GetFullName`, `GetClass`, `GetFName`, `HasAnyInternalFlags`
and friends are provided by UE4SS's metatable and are found *before* anything
reflection knows about. So `ksl:IsValid(someObject)` does **not** call
`UKismetSystemLibrary::IsValid` — it calls UE4SS's built-in on `ksl` itself,
ignores the argument, and returns true forever. Any engine function whose name
collides with a built-in has to be reached another way, or not at all.

**`UE.valid()` is not "safe to call into" — use `UE.alive()` for that.**
`valid()` answers "is there a UObject at this address". A controller whose
player has left is still there: the engine drops the `UNetConnection`, flags
the actor as garbage, and `FindAllOf` keeps returning it. `UE.alive()` adds
`IsActorBeingDestroyed` and the raw internal flags. It fails **open** on
purpose — each test only reports death on a positive signal, so with neither
available it degrades to exactly `valid()`. Getting that backwards would
switch the spawn ladder off for everybody, which is a far worse bug than the
crash it prevents.

**Engine strings are userdata here — `tostring()` gives you an address.**
`PlayerNamePrivate` reads back as `FString: 000001305A8CD158`, `NetDriverName`
as `FNameUserdata: 0000...`. Use `UE.ToStr()` / `UE.PlayerNameOf()`. This is
not only cosmetic: a `tostring(FName):find("Game")` comparison in the net
driver fallback could never match, making that path silently dead.

**`a == b` does not compare engine objects — use `UE.sameObject`.**
UE4SS returns a fresh Lua wrapper for every lookup, so two references to one
actor can compare unequal. Measured: `rt.why` labelled the local player's own
pawn "OTHER PLAYER" next to the real one, because `p == UE.GetPawn()` was false
for the pawn it had just got *from* `GetPawn`. Compare full names.

**A repeated failure is as expensive as a crash.** A Lua error inside the tick
loop is caught, logged and retried at tick rate forever — one produced 15,000
stack traces and an 18 MB log in a session, each line flushed to disk on the
game thread. `Safety.guard` retires an operation after three consecutive
failures; `log.lua` collapses identical consecutive lines and rotates past
4 MB. Failing safely, failing quietly and failing *repeatedly* are three
different things.

**Never hold an actor pointer across frames.**
This game spawns and despawns AI customers constantly. A list returned by
`FindAllOf` can contain an actor that begins destruction before you reach it,
and calling into a half-freed `UObject` through UE4SS is an access violation in
native code — **`pcall` does not catch that**, it traps Lua errors, not memory
faults. This crashed the mod twice. Every module re-resolves objects each tick
and keys its bookkeeping on name strings.

**Never touch an actor from a construction notification.**
Objects reported by `NotifyOnNewObject` are still being built. Calling
`SetReplicates` on one reaches into the world's network list mid-construction
and takes the process down.

**Never hook `/Script/Engine.Actor`.**
It fires for every actor the game creates — thousands, continuously.

**Never do a full `ForEachUObject` sweep.**
Walking the whole object array and calling `GetFullName()` on every entry
touches objects that are mid-construction or already freed. It crashed the
process on launch. `StaticFindObject` with a known path is exact and safe.

**Replication is done on class default objects, not instances.**
`AActor` copies `bReplicates` from its CDO and derives `RemoteRole` from it
during `PostInitializeComponents`, so patching a CDO once makes every future
spawn of that class replicate with no per-actor work forever after. One
instance pass per class catches what already existed, then that class is never
swept again.

**On a listen server, a remote controller has a valid `Player`.**
`UNetConnection` derives from `UPlayer`. Any "is this mine?" test based on
`pc.Player ~= nil` will happily return the *guest's* controller on the host.
Use `UE.IsLocalController()`.

**There is no reflected `GetNetMode`.**
`GetNetMode` lives on `AActor` and `UWorld` as plain C++. `UE.GetNetMode()`
reproduces `UWorld::InternalGetNetMode` instead: no net driver → standalone;
a driver with a `ServerConnection` → client; a driver without one → server.

**`GetCurrentLevelName` does not resolve on this build.**
It always falls through to a guess. Anything deciding "is the player really in
a level" must judge from the **pawn** (`Player_Character_C` exists in the store
and not in the menus), not from the map name.

---

## 6. The guest black-screen problem (v1.4.0, `spawn.lua`)

Worth understanding in detail, because it is the most recent work and the least
verified.

**Symptom.** The guest connects — the host logs `a player joined (2 connected)`,
the net driver shows the connection — and the guest sits at a black screen
forever. Nothing errors on either machine.

**Cause.** They have no pawn. A `PlayerController` with no pawn also has no
view target, so the camera renders from the world origin, which in this store
is inside solid geometry. Hence black rather than "floating in space".

The engine's login path is
`PostLogin → HandleStartingNewPlayer → RestartPlayer → SpawnDefaultPawnFor(FindPlayerStart)`.
A single-player GameMode only ever has to satisfy the parts its own startup
uses, and this one has never in its life had a second player log in. Any of
these breaks the chain, and **all of them look identical from outside**:

- `DefaultPawnClass` not set to the store character — the game builds and
  possesses `Player_Character_C` from its own Blueprint, for player 0 only;
- no `APlayerStart` in `L_Player_Store_01`, so `FindPlayerStart` returns null
  and `RestartPlayer` quietly gives up;
- a Blueprint override of `HandleStartingNewPlayer` that never calls
  `RestartPlayer`;
- `bStartPlayersAsSpectators` / `bDelayedStart` suppressing the restart.

**What the live test actually found.** None of the above. The engine's login
path is *healthy* on this build: `Core_Gamemode_C`'s `DefaultPawnClass` really
is `Player_Character_C`, the level really does contain a `PlayerStart`, and the
guest arrives with a proper character without the ladder below ever running.

The real cause was **where** the pawn lands. Measured: the guest spawned at
`Z = -408` against the host's `Z = 96` — 544 units below the floor. There is
exactly one `PlayerStart` in a game that has never used one, because Retro
Rewind puts you in your shop from your save file, not from a spawn marker, so
nothing has ever had to be correct about where that marker sits.

Guests are therefore moved next to the host ~1.5s after arriving, and their
view target is set explicitly. Those are two different causes with one
symptom: a pawn under the floor, and a camera with no view target rendering
from the world origin — which in a store built away from the origin *also*
looks exactly like being under the map.

The ladder below is kept. It cost nothing, it is what proved the login path
healthy, and a game patch that moves `DefaultPawnClass` would need it.

**The ladder.** Do not guess which rung is needed. Watch for a connected
controller with no pawn, give the game's own login path first refusal, then
escalate through five routes, logging which one worked:

1. `HandleStartingNewPlayer` — the game's own path, so a working Blueprint
   override keeps its behaviour.
2. `SpawnDefaultPawnFor` at a `PlayerStart`, or failing that at whatever actor
   the host is standing in — the parameter is an `AActor*` and only its
   location and yaw are read, so **any** actor serves as a spawn point.
3. The same, with `DefaultPawnClass` temporarily pointed at the store's
   character class and put straight back afterwards. This keeps ownership,
   instigator, collision handling and possession all on the engine's own path.
4. Building `Player_Character_C` directly via
   `BeginDeferredActorSpawnFromClass` / `FinishSpawningActor`.
5. Adopting a `Player_Character_C` that nobody is driving.

Routes are ordered so that the ones needing an **`FTransform`** come last:
passing one means handing UE4SS a nested Lua table for a struct containing a
quaternion, and whether that marshals correctly is a property of the UE4SS
build rather than of this game. Every rung that can avoid it, does.

Possession is always followed by `SetViewTargetWithBlend`, which replicates to
the owning client. Possession alone does not end the black screen.

**Only the host needs this.** Spawning and possession are authority-only. The
guest half of `spawn.lua` does nothing but notice and explain, so that somebody
staring at black is told why.

**The ladder must never run on a controller that is leaving.** This is the one
crash this file has produced, and it is subtle: a departing player looks
identical to a pawnless one. Their pawn has just been unpossessed and is left
standing in the store, and their `PlayerController` keeps coming back from
`FindAllOf` for a while after the `UNetConnection` is cleaned up. Calling a
GameMode login function with it reaches into memory that is being freed —
which `pcall` does not catch, because it traps Lua errors, not memory faults.
`isLiveGuest()` gates every rung, every placement and `rt.fixpawns` on:
`UE.alive(pc)`, not local, and `UE.alive(pc.Player)` — the `UNetConnection`
being the proof that somebody is still on the other end.

Each rung also logs a line *after* it returns. `Log.guard` can report a Lua
error and cannot report a native one, so without that the log simply stops and
"the route ran and did not help" is indistinguishable from "the route took the
process down". That ambiguity is what made this crash take a session to read.

**Commands:** `rt.pawns` prints the diagnosis (who has a pawn, the GameMode's
`DefaultPawnClass`, the level's `PlayerStart` count, possessed vs unpossessed
characters). `rt.fixpawns` re-runs the whole ladder immediately.

---

## 7. Working on it

**Edit → deploy → test:**

1. Edit in `RewindTogether\Mods\RewindTogether\Scripts\`.
2. Copy changed files to the deployed path in §2.
3. Launch from **Steam**, not the exe (the game relaunches itself through Steam
   anyway, but launching direct confuses UE4SS's startup).
4. Watch the UE4SS console window, or read `UE4SS.log` afterwards.

**Check before deploying.** There is no Lua binary here, but both a real parser
and a real interpreter are one install away:

```bash
py -m pip install luaparser lupa
```

then run `Check-Mod.py` in the project root. It does two passes:

1. **Parse** every script in both copies — source and deployed. A mistyped
   `end` otherwise costs a whole game launch to find, because UE4SS simply
   declines to load the mod and the game comes up looking normal.
2. **Run** the mod against a fake UE4SS in `test/`. Every module loads,
   `main.lua` boots, the tick loop is driven, and every `rt.*` command is
   invoked. Then the two situations that have actually broken this project are
   replayed: a guest who needs a pawn (the ladder *must* fire) and a guest who
   is disconnecting (the ladder must *not* — that is the crash in §6).

It exits non-zero on any failure, so it can gate a deploy. Extend `test/smoke.lua`
whenever a bug is fixed; a regression caught here costs seconds instead of a
two-machine test.

The fake in `test/harness.lua` deliberately reproduces UE4SS's quirks rather
than an idealised engine — `RegisterHook` refuses the hooks that carry no
reflection data on this build, and object stubs answer the built-in members.
When it and the real thing disagree, the real thing is right; fix the harness.

**Set `Config.LogLevel = "debug"`** when investigating anything; it logs
discovered function signatures and every packet type.

**`rt.diag`, `rt.status`, `rt.pawns`** dump state from inside a live session.
The self-test in `net.lua` runs automatically once per launch and writes what
the build actually supports — reflected signatures, the GameMode's login
functions, the net driver definitions — to the log. Extend that rather than
reasoning about what "should" be there.

---

## 8. Conventions this codebase follows

- **Ask the build, do not assume.** The self-test exists because one wrong
  assumption about a UFUNCTION's reflection cost an entire evening. If you are
  unsure whether something is callable, log what reflection says about it.
- **Comments explain *why*, and especially why-not.** Most of the long comment
  blocks record a failure and the reasoning that resolved it. They are the most
  valuable thing in the repo — keep writing them, and do not compress them away.
- **Everything that touches the engine is `pcall`-guarded** and tolerates
  `nil`. Objects come and go across level travel.
- **Never report success for something that was merely dispatched.**
- **Diagnostics are user-facing.** When something fails, print the `=====`
  block that says what failed, why, and what to do instead — both players are
  non-technical and the console is the only UI that reliably works.
- **Anything that can crash natively goes behind `Safety.guard`.** A crash
  cannot be caught, but it can be observed afterwards: the breadcrumb file says
  what was in flight, and the next launch retires that operation and explains
  itself. Without it a player relaunches into the identical crash forever and
  concludes the mod is broken. Name the operation in words the player will
  understand — the string appears verbatim in `rt.safety`.
- **A config mistake must never fail silently.** `Safety.checkConfig` repairs
  what it can in memory and reports everything. It never writes to
  `config.lua`; the file is the user's.
- **A new option whose absence equals its default does not need a
  `ConfigVersion` bump.** Bumping it makes the installer replace the user's
  `config.lua`, which throws away their `JoinTarget`. `Config.AutoSpawnGuestPawns`
  is deliberately checked with `== false` so a missing value counts as on.

---

## 9. Where this is going — the public release target

The intent is a **Nexus Mods release: the first multiplayer mod for this
game.** That is a different bar from "works for the two of us", and the gap is
mostly *not* networking. Everything in this section serves one sentence:

> Install with one double-click. Launch. Load your save. Press F7. Your friend
> clicks **Join Game** in Steam. That is the whole thing.

Nothing in that sentence requires the user to know their IP, their port, their
Steam ID, or that a tunnel exists. Any feature that breaks it is a bug,
regardless of whether it works.

### Does it need Tailscale? No.

Tailscale is one of four routes and happens to be what the developers tested
on. The mod uses plain `IpNetDriver` and needs only a path to the host on UDP
27015:

| Route | Setup cost | Over the internet |
|---|---|---|
| Same house / LAN | none | no |
| UPnP port forward (`OPEN PORT` bat) | one click, many routers refuse | yes |
| VPN (Tailscale / ZeroTier / Radmin) | both install an app, join a network | yes |
| `tunnel\RewindTunnel.exe` over Steam relay | both run a second window | yes |

**Only the fourth is acceptable for a public release**, and it already exists.
The others stay as documented fallbacks, not as the path anyone is asked to
walk.

### The gaps, ranked by how badly each hurts a release

**1. Config editing — disqualifying.**
A user currently has to open a `.lua` file and fill in `JoinTarget`,
`PeerSteamIds`, and verify `Port`. Most people will quit before finishing.
Every one of those can be discovered at runtime, and `steamjoin.lua` already
contains the parts. The design that removes config entirely:

> Host presses F7 → the mod publishes Steam rich presence with a connect
> string → the friend clicks **Join Game** in their Steam friends list → their
> game reads the host's SteamID from the invite → sends a `hello` → **the host
> learns the guest's ID from that packet.**

Zero typing, zero addresses, both directions discovered. Presence is currently
off (`Config.PublishSteamPresence = false`) because it advertised
`steam.<id>`, which the dead Steam net driver could not honour — see §5. Point
the connect string at the tunnel instead and it stops being a trap.

**2. The tunnel is a second manual window.**
Requiring both players to launch an exe, in the right order, after hosting, is
the remaining friction. UE4SS's Lua has `os.execute`, so the mod can start and
stop the tunnel itself and the user never sees it. This collapses the most
error-prone step in the whole flow into nothing.

**3. Console-only UI.**
Everything the mod says goes to the black UE4SS window. To a Nexus audience
that reads as broken. **This one is blocked**: the in-game overlay crashes,
which is why `Config.SafeMode` defaults on, and that crash was never isolated.
Solving it unblocks nametags too.

**4. The two open gameplay bugs — and one of them is the real project.**
Players not seeing each other is bounded work (see §4; possibly borrowing an
NPC skeletal mesh as a visible proxy, once `rt.why` says whether the pawn even
replicates). **The yellow boxes are the deep one.** The store's props take
their appearance from Blueprint variables that were never marked replicated,
and replication cannot be added to a cooked build. Mirroring them means
shipping per-actor state over the side-channel ourselves — a real feature, not
a fix, and the difference between "co-op" and "co-op where the shop actually
looks like a shop".

### Rough effort

- Gaps 1 and 2: an evening. Takes the mod from "needs a written guide" to
  "behaves like a normal mod".
- Gap 4 (props): the actual project. Budget accordingly.
- Gap 3: unknown until the overlay crash is isolated.

### Rules for anything shipped publicly

- **No step that requires editing a file.** If a value is needed, discover it
  or ask for it in-game.
- **No step that requires the two players to coordinate ordering.** "Start
  yours before mine" is a support ticket.
- **Never advertise a join route that cannot work.** This project has already
  lost days to exactly that (§5); a Nexus audience will not debug it, they
  will post a one-star comment.
- **Every failure says what failed and what to do instead.** The `=====`
  diagnostic blocks are not clutter, they are the support burden being paid
  down in advance.

---

## 10. Open questions

Answered since the first draft: the spawn ladder never fires (the login path
is healthy — §6), and state sync never ran at all (`Net.addPeer` had no
callers — §4).

Still open, roughly in the order they should be attacked:

- **Does the side-channel carry a packet?** Everything downstream of it — state
  sync, chat, interaction forwarding — has never been observed running, and two
  separate bugs have now been fixed underneath it. `rt.status` reports
  `sent / failed / received`; anything non-zero on both machines closes this,
  and the `SendP2PPacket (...)` line logged at startup names the real signature
  if the shape probe still cannot find one that works. **Check this first** —
  three of the remaining questions are unanswerable until it is true.
- **Why does runtime component construction not work?** Still open, and one
  attractive answer has now been ruled out — read this before trying again.

  1.5.1 blamed the argument list: both callers passed
  `(cls, outer, name, 0, 0, nil, false, false, nil)` against UE4SS's
  `(Class, Outer, Name, SetFlags, InternalSetFlags,
  bCopyTransientsFromClassDefaults, bAssumeTemplateIsArchetype, InTemplate,
  ...)` — a `nil` where a bool belongs and a `false` where a `UObject*`
  belongs. Handing a boolean to a pointer parameter is exactly how you crash in
  `StaticConstructObject_Internal`, so `Config.SafeMode` was defaulted off.

  **Measured on two machines: that was not it.** With the three-argument form —
  which cannot have wrong types in it, there being nothing after `Name` — the
  component still comes back unusable: it passes `UE.valid()` (so
  `UObject::IsValid` returns true on it) and then `RegisterComponent` reports
  *"Tried calling a member function but the UObject instance is nullptr"*.
  1,275 failures on one machine, 15,000 on the other, in one session.

  So the object UE4SS returns is a wrapper around a null pointer that
  nonetheless claims to be valid. **Corollary worth its own line: `UE.valid()`
  cannot be trusted on a freshly constructed object** — only actually using it
  proves anything. Next thing to try is a different construction route
  (`AActor::AddComponentByClass`, or `K2_` component helpers) rather than
  another set of arguments to the same call.
- ~~**Do players see each other, and if not, why?**~~ **Answered.** Both
  machines render the other player as a borrowed NPC body. The pawn replicates;
  the missing third-person mesh was the whole problem. What is left is
  cosmetic and tracked in §4: the body's placement and its animation.
- **Does a borrowed animation blueprint actually drive a Player_Character_C?**
  New in 1.5.8 and the likely reason the T-pose outlives the placement fix. An
  AnimBP written for an NPC that casts `TryGetPawnOwner()` to its own class
  gets a `Player_Character_C`, fails the cast, drives nothing, and outputs the
  reference pose — which is a T-pose, and is indistinguishable from "the class
  never applied" unless you ask. `rt.bodies` now prints whether an
  `AnimInstance` exists. If it does and the body is still T-posed, this is the
  answer, and the route out is single-node playback (`SetAnimationMode(0)` +
  `PlayAnimation`) with an `AnimSequence` on a compatible skeleton rather than
  another attempt at the blueprint.
- **Does the guest need a local GameMode?** `rt.localgm` builds one and is
  untested. The guest having no GameMode is measured, and it explains more than
  the missing money: a guest screenshot shows their world at **night** while
  the host's clock reads Sun 8:00 AM, and the guest has no HUD at all. Day
  length, HUD and store simulation all hang off an object that does not exist
  on their machine.
- **Do the `Config.SyncedState` property names exist?** Still unverified,
  because the code that reads them was unreachable until 1.5.0. `rt.state` on
  both machines settles it and shows the real names.
- **What puts the guest's store in build mode?** A guest screenshot changed
  this question. The store renders under yellow-and-black hazard stripes with a
  placement footprint on the floor — but every mesh and texture *underneath is
  correct*. So it is not per-prop appearance data, which is what §9 gap 4
  assumed for two versions and which would have meant mirroring per-actor state
  for hundreds of objects. It is a build/placement **mode** the guest's client
  is in and the host's is not, and quite possibly a single bool.
  `rt.state` now searches for mode/phase names across the GameInstance,
  GameMode, GameState, controller and pawn. Run it on both machines and diff.
- **Does interaction forwarding do anything useful?**
  (`Config.ForwardGuestInteractions`.) Untested — nobody has worked the shop
  together yet.
- **Why does the overlay crash?** (`Config.SafeMode`.) A
  `TextRenderComponent` constructed on a live pawn; the construction is the
  suspect but was never isolated. Blocks all in-game UI, which blocks §9 gap 3.
