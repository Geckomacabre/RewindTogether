# MODLOG — Rewind Together, session of 2026-10-14

Journal for this session. PROJECT.md is the brief; VERSION.txt the changelog.

## Goal (agreed with the user)
"Ready for Nexus": no config editing, friend clicks Join Game in Steam, tunnel
starts itself, sync/interaction verified, docs for strangers.

## Paths
- Game: `D:\SteamLibrary\steamapps\common\RetroRewind` (AppID 3552140)
- Deployed mod: `...\RetroRewind\Binaries\Win64\ue4ss\Mods\RewindTogether\Scripts`
- Source (edit here): `%USERPROFILE%\OneDrive\Desktop\RewindTogether\Mods\RewindTogether\Scripts`
- Deploy: `sh dev/deploy.sh` (keeps the deployed config.lua; `--with-config` to overwrite)
- Logs: `...\Binaries\Win64\RewindTogether.log`, `...\ue4ss\UE4SS.log`
- Saves: `%LOCALAPPDATA%\RetroRewind\Saved\SaveGames` (Player_Save1 = main, Player_Save2 = small)

## Backups / restore
- Saves: `%USERPROFILE%\.universal-modder\backups\retrorewind-saves\20261014-140052.zip`
  (`um backup restore retrorewind-saves`)
- Config folder: `...\backups\retrorewind-config\20261014-140052.zip`
- Deployed config.lua: `...\ue4ss\Mods\RewindTogether-config.lua.pre-claude-backup`
- UE4SS-settings.ini: `...\ue4ss\UE4SS-settings.ini.pre-claude-20261014`

## State found at start
- Code is 1.6.1 per VERSION.txt, but `Net.VERSION` still says "1.5.8" (rt.status lies).
- Last two-player test: 2026-08-05 (1.5.8). 1.6.x never tested with a guest.
- Oct 9 run was solo; no errors.
- Deployed config.lua is an older file with PeerSteamIds set (friend "Walmeezie").
- Unverified guesses: `Config.SyncedState` property names, the interaction
  function name list in sync.lua.

## Dev tooling added
- `devbridge.lua` — only active if `Binaries\Win64\RewindTogether.devbridge` exists.
  Slot A = first instance, B = second. `py dev/bridge.py A rt.status`,
  `py dev/bridge.py A "lua return UE.NetModeName()"`.

## Log

### 2026-10-14 — two-instance testing on one PC (works)
- Instance A: Steam launch, hosts. Instance B: `RetroRewind-Win64-Shipping.exe RetroRewind`
  started directly with env SteamAppId=3552140 (otherwise Steam just refocuses A).
  `py dev/coop_test.py up|down|log`. Bridge slots A/B; traces in Win64\RewindTogether.trace.<S>.
- Clicks only work at the window's native 1920x1080 client size; the FIRST click after
  focusing is eaten (activation) — click twice. Menu points: PLAY (242,675), slot 1 (750,140).
- **Joining from the main menu works** (OpenLevel 127.0.0.1 → Client in ~2 s). No save needed.
- CXX header dump: `%USERPROFILE%\RetroRewind-decomp\CXXHeaderDump` (outside repo).
  Money = Core_Gamemode_C.Money (int64 cents); Level/Experience/Lifetime Experience/Store Value.
  Clock = WeatherSystem_C (Day, Hour, Minute, Year, Season, DayTime, Current Weather,
  Day of the week); its minute timer: "Stop or pause Timer - Add one minute".
  HUD = UI_Player_Interface_C (Change Money Value / Change Time / Change Week Day / Change XP Value),
  built only by Core_Gamemode_C ("UI Game Interface" property).
  Interactions: IInteraction_C::Interaction(bool& Accept Interaction); player side
  Player_Character_C "Trace from Camera for Interaction", input events InpActEvt_Input_Use_*.
  Hazard stripes = StoreExpansion_C walls of unbought expansions (Unlocked, "Unlock Expansion"(bInstant)).
  Store sign = StoreName_C (Name FText, Color, Size, "Set StoreName Visual").
  The game itself has unfinished MP scaffolding: GameInstance "is Multiplayer"/"ExpectedPlayers",
  GameMode "Look for Multiplayer", "Player Controller logged".

### Crashes found and fixed (1.7.0)
1. Host died the instant a guest joined: rpcchan passed a Lua string for ClientMessage's FName
   param → UE4SS access violation (0x70). Reproduced deterministically on a spare instance;
   FName("...") form is fine. Smoke test now rejects non-FName.
2. Host/guest died 40–145 s into sessions inside Lua's GC (garbage pointers like 0x6b636a6d):
   LoopAsync runs Lua on UE4SS's async thread concurrently with game-thread Lua. Switched to
   LoopInGameThreadWithDelay (present in this UE4SS build). Soak: 6 min, 0 crashes (was 3/4).
   Keybind callbacks now only ExecuteInGameThread; the always-on LEFT_MOUSE_BUTTON bind removed.
3. Engine's own spectator ServerSetSpectatorLocation calls during login were replayed as
   guest interactions → now marked with Roll=77.25.
4. localgm stripes: Safety.guard returns one value → nil compare every guest join.
- UE4SS marshalling gotchas (each measured, each a native crash or refusal):
  * Lua string -> FName param: CRASH (use FName("x")).
  * Lua string -> TSoftObjectPtr param (WeatherSystem "Load Level for Season"): CRASH.
  * Out params (bool&): UE4SS 3.0.1 does not advance past the out-param table, so any
    UFunction with an out param FOLLOWED by more params cannot be called
    (LevelStreamingDynamic::LoadLevelInstance). Empty "" also refused for an FString.
  * Struct fields come back keyed by the FName table's casing: FRotator "pitch" (lowercase).
- Season sub-level: host streams /Game/VideoStore/asset/level/Season/L_Store01_Season-<Season>
  as LevelStreamingDynamic at identity; a guest never loads it (no GameMode) → no snow,
  different fog/colour. Snow Accumulation 0.5 vs 0.
- Ghost-mode stripes: NavCollisionZone_C + M_GhostMode_NavBlocker; "Toggle Ghost Mode
  Blockers"(false) on the guest hides all (fixed in worldsync.lua).

### Native helper (RewindNative.dll) — works
- UE4SS's C++ SDK needs the private Re-UE4SS/UEPseudo repo (Epic-linked GitHub only) → not
  available. Instead: `package.loadlib` (enabled in this UE4SS) loads native\RewindNative.dll;
  exports are lua_CFunctions that use UE4SS's exported `RC::LuaMadeSimple::Lua` wrapper
  (ctor/get_integer/set_integer/...; dtor does NOT close the state — LuaMadeSimple.cpp @0196ef29).
- Player-0 redirect: swap UFunction::Func (+0xD8 on this build, found by scanning for the first
  pointer into the exe's .text) of GameplayStatics GetPlayerController/Character/Pawn/
  CameraManager with thunks that call the original, then replace host→guest results while a
  window is open. `rt.native test` PASS live. DLL pins itself (Lua 5.4 FreeLibrary()s on reload).
- Build: `native\RewindNative\build.bat` (VS 2022 Community has MSVC 14.44; no install needed).

### Guest interactions — pick-up works
- FINDINGS (%USERPROFILE%\RetroRewind-decomp\FINDINGS.md, bp\*.txt): RMB _23 = interact
  (Trace from Camera for Interaction from self.Camera, box (1,2,2), dist = Move Tool 200),
  LMB _20 = per-tool trace (hand: physics / place when holding), E _1 = hand tool, V _2, B _3,
  K _0. 410/414 GetPlayer* calls pass 0. Item/hand code works on Self. No BP RPCs.
- guestinput.lua: guest sends (code, camera loc/rot) via ServerSetSpectatorLocation with
  Roll = 100+code; host sets the guest pawn's Camera to that view, then in a Native.asPlayer
  window calls Look At Test + the input event on the guest's pawn. MEASURED: guest picked up
  "Rain Woman" (host: guest Object Hold = videotape, host holds nothing; guest sees it in hand).
- HUD calls go to the GameMode's single widget (the host's) → during a replay the GameMode's
  "UI Game Interface" is set to nil and restored (host HUD showed the guest's tape before).
- Host disables the guest pawns' actor tick (their Look At Test highlighted guest targets on
  the host's screen; the game never checks IsLocallyControlled).

### NPC looks — guest crash hunt
- Guest died 3× on a Foreground Worker (UE task thread), EXCEPTION_ACCESS_VIOLATION reading
  0xffffffffffffffff, same top frames (+3bbbb73, +343e969, +2573f5a, +259ca39), 2–3 min after
  NPC looks were applied. NPC sync off: clean 5 min. Looks off/state on: clean 4.5 min.
- Fixes: (1) never CreateDynamicMaterialInstance under a fixed name (same-name NewObject
  destroys the live MID in place) and don't re-apply unchanged looks; (2) body swap via
  SetSkinnedAssetAndUpdate(mesh, true) — SetSkeletalMeshAsset is SetSkeletalMesh(..., false)
  and keeps the old pose buffers.
- Minidump thread names via the ThreadNamesStream (dev: scratchpad md2.py).
- ROOT CAUSE FOUND (soak 8: 8 min clean with looks on, was 109–161 s every time): npcsync cached
  loaded asset objects in a Lua table across frames; GC freed them after their NPCs despawned and
  the cache handed out dangling pointers. Crash instruction disassembled (capstone on the exe):
  `cmp byte [rax+0x89]` after reading [component+0x560] = USkinnedMeshComponent::SkinnedAsset /
  UStaticMeshComponent::StaticMesh (header dump offsets). Assets are now re-resolved every time.
  (Queued delivery + SetSkinnedAssetAndUpdate + unique MID names kept as good practice.)
- Mouse-free host load for tests and the launcher: GameInstance."Save Slot"="Player_Save1" then
  OpenLevel(L_Player_Store_01) — from FINDINGS 3e. launch.json host may carry "slot".

### Put-back on the guest + the lookup cost (2026-10-14)
- Guest saw a put-back tape floating. Cause: on the guest `bReplicateMovement` was false on 395
  of 396 tapes. Two reasons, both MEASURED: (1) a Blueprint actor copies only a precomputed
  property list from its class default when it spawns — a tape spawned on the host after its
  CDO had both flags came out `bReplicates=true, bReplicateMovement=false`; (2) with the host's
  CDO patched to true, the flag was never sent (Unreal sends only where a value differs from
  the class default). Fix: never patch bReplicateMovement on a CDO; host sweep checks every
  actor's own flags continuously (1 slice/s, 4 classes); guest sweep flips the flag and calls
  OnRep_ReplicatedMovement (stored ReplicatedMovement non-zero, not attached). Hand-setting the
  flag on the guest tape made the host's nudge visible at once. Release nudge removed.
- PERF: UE4SS FindAllOf/FindFirstOf = 15–17 ms per call (hit or miss, any class); StaticFindObject
  1–2 ms. Wrapped and counted live for 10 s: host 60% of wall time in lookups (GetAllPlayerControllers
  22/s), guest 53% (patchGuestMovement retrying non-existent bare class names every tick).
  Engine route (ue.lua): GameInstance (one walk per process) + GameplayStatics
  GetNumPlayerControllers/GetPlayerController/GetGameMode/GetGameState (µs);
  KSL MakeSoftObjectPath→Conv_SoftObjPathToSoftObjRef→Conv_SoftObjectReferenceToObject = 0.02 ms
  (null path → wrapper around nullptr, check IsValid); GetAllActorsOfClass (out param last: works)
  479 tapes in 4 ms; GetActorOfClass 0.008 ms. Conv_SoftObjPathToSoftClassRef is NOT callable.
  FindAllOf("BlueprintGeneratedClass") returns nothing in this UE4SS. Per-tick cache closed by
  UE.endFrame(). Objects re-found by path (UE.pathOf/findObject) — HUD widget 0.03 ms.
- First engine-route build: host sweep patched nothing and expansions read 0 — GetAllActorsOfClass
  out-table elements are RemoteUnrealParam (need :get()). UE4SS source (0196ef29
  LuaUObject.cpp call_ufunction_from_lua): params live in `DynamicUnrealFunctionData{uint8_t
  data[0x200]}` on the stack, never destroyed → engine allocations made for params/returns leak
  (out arrays: 8 B/element; UE.findObject's FString path: ~0.6 KB/call measured, 100k calls
  +124 MB vs control +19 MB). Struct returns are converted to plain Lua tables.
- After fix: host 727 actors patched at session start; expansions 6; guest tapes 397/397 with
  bReplicateMovement; guest put-back verified both screens (rack slot 1966,-1190,139, nothing
  near the hand). Lookups 2.4% of wall on both (was 60/53%). Launcher: 170/170 tests.
- Leak budget: findObject memoized per tick, native classes cached for good, NPC sync lists
  AI_Base_Character_C once instead of 4 classes. Sweeps: host 1 slice/2 s, guest 1 slice/2 s.
- Second leak, worse: UE4SS make_ref()s every out-param table into the Lua registry and never
  unrefs it → every actor list (+ its RemoteUnrealParam wrappers) lives forever. Registry grew
  ~4/s; guest live Lua heap 31 MB and rising. Fix: UE.releaseOut(t) (nil the registry entry whose
  value is t; newest refs are at the end of the array part), UE.withHit for K2_Set* FHitResult.
- Guest neon red again on one run: the sign lights were applied in the second the guest joined.
  Re-running "Update Materials for Lights"/"Update for Lights" later turned it blue → re-run them
  on each world message (2 s) for 30 s after the first application.
