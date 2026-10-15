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

### Guest HUD: what you hold and look at (2026-10-14, late)
- The plan in PROJECT.md 0 (answer GetGameMode with the HUD widget) would have done nothing: the
  widget's UI_Interface_C events are all empty stubs (bp UI_Player_Interface__game_ui @1025-1031);
  only Core_Gamemode_C's events forward to "UI Game Interface".
- Census of the dump: 78 Blueprint GetGameMode calls, each followed by a cast of the result -
  51 Cast<Core_Gamemode_C>, 24 ToInterface<UI_Interface_C>, 1 each to Ghost_C, OptionApply_C,
  MainMenu_GameMode_C. The HUD display calls (product in hand, context menu, cursor style, look-at
  detail, cursor visibility) all live in the UI_Player_Interface_C function library
  (core/blueprint/function - same short name as the widget in core/widget/game_ui).
- RewindNative v2 (rt_hook_null, rt_standin_arm/disarm/stats): GetGameMode answers null with
  Core_Gamemode_C's CDO only for VM frames (FFrame Code non-null) of that library whose next
  statement is EX_Let/EX_LocalVariable/EX_ObjToInterfaceCast(UI_Interface_C). Liveness of the CDO
  and the widget is checked on each answer through UE4SS's exports (IndexToObject/GetUObject,
  UObjectBase GetInternalIndex/GetObjectFlags/GetClassPrivate/GetOuterPrivate).
- MEASURED live: armed on its own (GetOffset_Internal works; CDO frame present); Lua's
  UE.GetGameMode() still invalid on the guest; ~1000 Blueprint GetGameMode calls/s on a guest;
  look-at gave the hand cursor and the "USE" hint on the guest's HUD.
- Product in hand did NOT appear from the stand-in alone: the host's replay picks up, the guest
  sees the tape on its hand (attachment replicates), but the guest pawn's own Object Hold stays
  empty, so Set Object Hold (which calls "UI - Set Visible Product in Hand") never runs there.
  Calling the pawn's Set Object Hold with what is attached to its "AttachObject Socket" made the
  panel appear ("THE MAILBOX'S BURNING POINT  MOVIE ACTION"). hud.lua now does that at 4 Hz while
  the stand-in is armed. Spawned tapes have different names on host and guest
  (videotape_C_2147469324 vs _2147475982), so the guest reads its own socket.
- End to end: pick up (panel), swap at the RESERVED rack (panel follows), throw to the floor
  (panel gone), host HUD never shows the guest's tape, rt.leave (disarmed, CDO released), rejoin
  (re-armed on the new widget). 19,823 answers, 0 stale, no crash, no breadcrumbs.
- Tooling: dev/coop_test.py `up` stops at client_point() when dev/gw.py has no WinDrivePid.ps1
  (RT_WINDRIVE); the bridge steps it runs work by hand. `py dev/gw.py ps` is not sorted by start.

### Guest actions: till, build mode, skin tool, selling, end of day (2026-10-14/15)
- Read off the Blueprints first (bp/MembershipMachine, CheckOut, Wall, AC_MeshSkin, Core_Gamemode).
- Every guest action had arrived with pitch 0: UE4SS fills an FRotator param by the name
  table's casing ("pitch"). UE.rotArg. A floor-level standee was out of reach until then.
- replication.lua wrote bReplicates before SetReplicates -> runtime spawns (build-mode boxes)
  never reached guests. Toggling SetReplicates on the host showed the box at once; fixed order.
- Guest walls/floors/ceilings/counter were the level defaults: only the save loader applies
  AC_MeshSkin. skinsync.lua (Load Asset(true) resets the skin to 0 - measured; use false with
  "Savegame data loaded" = false). Guest matched the host 2 s after joining.
- Till: entered for the guest by the host (Walking Mapping Context is host-only), glide stopped
  + finished as the guest, guest's game told to follow, W -> action 7, Space -> action 9, drawer
  + display mirrored (it stayed shut on the guest), exit spot fix (navmesh is host-only: the
  guest landed at 0,0,92), host hint cleared via the pawn's Init Cursor and Interface. Card
  customer (+$75.25) and cash customer ($25 for $21, $4 change) both done by the guest.
- Skin tool: Hud.withStandInFor(class) arms the stand-in for the clicked object's flow class for
  one call; the game's picker opens on the guest; UI_SkinMode "Material Selected_Event" hooked
  -> action 8 -> host Set new Skin/Mesh -> skinsync. Real mouse clicks re-skinned carpet + shelf.
- Selling: worked; host HUD missed the money (HUD hidden during replays) -> refreshed after.
- End of day: no travel, guest stays connected through summary into day 2; guest presses ignored
  while "End of Day Interface" is in the viewport (the reopened door would start a 2nd one).
- A guest crashed once in Bodies.tick after a hot reload re-placed it beside the host while its
  till collision was off (it fell out of relevancy and came back). The HUD stand-in was then
  switched off by its probation file; rt.safety reset brought it back.

### Guest NPCs: walking, hair, faces, thought bubbles (2026-10-15)
- Same NPC side by side (the store's employee, probe of both copies): guest Character Scale 0 vs
  0.996, AnimBP play rate 0.0 vs 0.80, Hair/Facial-Hair attached to the capsule (inside the body)
  vs HeadTop_EndSocket, mouth/eyes plain MICs vs MIDs (Frame, Eyelid), Widget3D_QuestRequest
  shown vs hidden, badge "Text Name" vs "Adam", actor tick off vs on.
- Cause (bp/AI_Base_Character): BeginPlay -> Bind Init casts GetGameMode to Core_Gamemode_C;
  on a guest it fails, delays 1 s and retries forever, so "Step 2 of creation Skin" (Init
  Default Variable, Adjust Scale, Init Graph, tick on) never runs. AnimBP_Base: play rate =
  Max Speed Walk Scale * (1 / Character Scale); divide by zero answers 0.
- npcsync.lua: the look now carries size, walk rate, bubble height, eyelid height, hair/beard
  materials, all 8 body slots (mouth and eyes too) and the staff name; the state carries the
  bubble and its icon. Guest: SetWorldScale3D, the NPC's own "Attach Child to Skeletal", the
  mouth frame + Surprised/Angry morphs per emotion (AI Emotion's table), bubble shown/hidden and
  turned to the guest each tick. The NPC's own tick stays off: Limit Walk Speed by rotation
  would turn every NPC toward GetControlRotation = 0 (no AI controller on a guest).
- Found on the way: the guest's own AI_Director (started by ActorGatherer on every machine)
  spawned 12 walk-bys in a few minutes (Role Authority, no controller, frozen at spawn points,
  bubble up). K2_ClearTimer(director, "Event - Timer") + K2_DestroyActor on Role Authority NPCs.
- Verified: feet swing through a stride on the guest (GetSocketLocation RightFoot, camera on the
  NPC - bones only refresh when drawn), hair and face match in screenshots, an angry face shows
  on both (Frame 0.72, Angry 1.0), a popcorn bubble raised on the host shows on the guest turned
  to the guest and closes with it, a re-armed director is stopped and its spawn removed.
- Not mirrored: eye direction (animated every frame on the host), the NPC's look-at-player head
  turn (each copy's AnimBP does it for its own player). Player bodies (bodies.lua) are still the
  bare NPC body: bald, grey.

### The "Bodies.tick" guest crash, breadcrumb blame, hot-reload re-placement (2026-10-15)
- Dump UECC-...1919342548779CCA2F2A5BAEF49442F2: GameThread, AV at UE4SS+0x22ba30. RAX = FNV-1a
  basis, R11 = FNV prime, R9 = the faulting address, R8 = 0x20, R10 = 0x3ff. Disassembly (pefile +
  capstone, .pdata for function bounds): MSVC `_Forced_rehash` of a static
  `unordered_map<string_view, wstring>` + shared_mutex at UE4SS .data 0xf41118, the memo
  UE4SS+0x228570 that UE4SS's UObject member access (0x22b590, via the __index/__newindex thunks
  0x22a2f0/0x22a310/0x22acd0) uses for names. Keys come from 0x848050 = lua_tolstring + strlen +
  lua_remove: pointers into Lua's own strings. 4 nested pcalls below UE4SS's callback = Log.guard
  -> Safety.guard(dress) -> setRelLocation -> UE.withHit -> comp:K2_SetRelativeLocation.
- Log: the guest (pid 37636) had been hot-reloaded at 23:40 and 23:51 (Ctrl+R reloads BOTH
  copies - the "two loading lines"), crashed at ~23:52:3x dressing the host's re-created pawn.
- Blame: both copies shared RewindTogether-inprogress.txt; the host's guarded calls (bodies on
  the guest's lingering pawn every 2 s, rpcchan sends) deleted the guest's breadcrumb, leaving
  only the stand-in's probation file.
- RewindNative 3: signature (lea r12,[lock] ... mov rbx,FNV basis; then "cmp [rip+size], rax"
  naming lock+0x18), layout validated under the SRW lock (pow2 buckets, mask, 2 iterators per
  bucket, ring walk == count), unlink all nodes and leak them (DLL is /MT). test_namecache.cpp:
  real MSVC map, keys in VirtualAlloc'd pages, freed -> the 513th insert faults (the dump); after
  the purge 2000 inserts are fine; installed UE4SS.dll: exactly one match at +0xF41118.
- Lua: native.lua repairs at boot (before any module) and from a __gc sentinel at lua_close;
  UE.TryGet/TrySet/TryCall pin names, UE.pin for others, dev bridge keeps compiled chunks.
- safety.lua: RewindTogether-inflight.<n>.txt per running copy (token = addresses of the
  CoreUObject/GameplayStatics CDOs, beat, phase, probation + its phases, guard stack), written in
  place and flushed; slot = own token (hot reload) or first record not written for 10 s. Blame:
  innermost guard > probation feature if phase idle/its own > report the phase only.
- spawn.lua: no first placement for a pawn older than 10 s (GetGameTimeSinceCreation); placeGuest
  refuses a pawn with collision off or MovementMode 0.
- Live, two copies: name cache found on both (207/185 names, 512 buckets); 4 reloads, 9 repairs
  per process, 670-710 names dropped; the host never re-placed the guest ("made 61/110/289/320s
  ago"); a till-like guest (collision off, MOVE_None) not moved by a reload or rt.bring. Out of
  range needs the guest to MOVE: the server's view of an idle client's camera stays where it was
  (host pawn kept 24 s at -39,868; gone 3 s after a W press). Three cycles out of range and back:
  host pawn ..474695 -> ..470808 -> ..463792 -> ..459517, dressed each time through
  K2_SetRelativeLocation, no crash. Guest hung inside a guard (stand-in put on probation), killed,
  restarted: blamed only the guard; host's record untouched; rt.safety reset cleared it.

### Host-only visuals on a guest: titles, signs, register, change, preview, end of day (2026-10-15)
- Titles: ShelveTitle_C values (genre, tag, empty, visible) from the host, matched by place and
  yaw (a double-sided shelf has two titles on one spot at yaw +-90). "Default Text" was really
  TextSign_C's "User Text" (6/6 with words on the host, none on the guest): sent as "signs",
  set with UE.setText then "Update Text". After: 73/73 titles, 6/6 signs the same.
- FText writes: UE4SS writes 0x18 into a 0x10 FText. End-of-day rows vanished (Font Size
  4.98e+20), a TextSign's "UI Text Command" pointers were garbage. UE.setText =
  KismetSystemLibrary SetTextPropertyByName (FText last). worldsync's store sign used the bad
  write too.
- Register: "Add Product Scanned to the list"(name, nil tags, price, type) gave $0.00 at type
  FURNITURE and the guest hung ~30 s later (killed; records kept in the session scratchpad). The
  guest now creates UI_Screen_ProductScan_C (WidgetBlueprintLibrary Create) and fills it with the
  *ByName setters, then AddChild. Money on the table: Replication.patchActor per actor in
  "Array of Spawned Money on table ref" ($10/$5 bills seen on the guest's counter).
- Preview: ReceiveTick hook on Player_Character_C (runs after the BP), pawn matched by address,
  Ghost Tick with the furniture class's CDO for 0.35 s windows (the box's "Objects in Inventory"
  is not replicated). First live run: green on the guest at a spot where the host threw the box.
  Cause: Look At Test asks "Trace from Camera for LookAt Ghost" (reach by tool + 50 when looking
  at something) before Ghost Tick. Added; after: green at 1320,-1700 and the host placed the
  shelf at 1320,-1700 yaw -90; aimed close at a wall/shelf the guest showed no preview and the
  host threw the box (the box at 2426,-23 on both).
- End of day: UI_EndOfTheDay_C on the guest (buttons disabled), statistics texts, XP texts,
  ProgressBar percent, WidgetSwitcher page and three visibility digits (txt_LevelUp and two
  SizeBoxes - without them the guest showed "LEVEL UP!" over an empty box). Then UI_NewDay_C.
- User report mid-session: customers handed the guest a basket instead of money. bpdump:
  BTTask_Checkout-Pay "Setup Pay With Money" spawns Money_NPC-Stash_C into the hand on the host
  (also the membership-card and console-rent tasks); AI_Base "Toggle Visiblity Basket" only sets
  Has Basket, AI_Client's override hides the basket's StaticMesh - and npcsync only set Has
  Basket. Now: patchActor on each NPC's "Money Stash", and the guest calls Toggle Visiblity
  Basket on change.
- Live, after a restart of both: customers' baskets show/hide on the guest with Has Basket
  (vis false at the till, true while shopping). A first watcher crashed the GUEST: it named
  `stash:GetAttachParentActor()` with :GetFName() the instant the cash replicated, before the
  attachment had (AV reading 0x18 = null's NamePrivate, under UE4SS+0x229dd7). Probe bug, not
  the mod; noted in PROJECT.md. Then, with Adam idle at 22:00, the guest took the till, talked to
  the customer (damaged-tape fee), and she held out cash: Money_NPC-Stash_C at 1617,-1510,114,
  attached to the same customer on both (role 3 / 1), basket hidden on both, bills in her hand
  on both screenshots.

### Crash record: a clean exit is not a crash (2026-10-15)
- Game quit paths (bp): the store's ESC menu opens L_Boot (map load -> Hud.reset -> stand-in
  trusted); only UX_Boot_Menu calls QuitGame. The bad cases were window close / Alt+F4, Steam's
  Stop and killed copies, which left the same record as a crash.
- Measured (one copy, WM_CLOSE via taskkill without /F): the process is gone in 2 s; no Lua
  finalizer runs (UE4SS does not lua_close at exit) and a RegisterHook on
  GameInstance:ReceiveShutdown never fires. The Safety "closed" finalizer therefore only ever
  fires on hot reloads.
- RewindNative: rt_crashes_since(t, pid) (report folders under %LOCALAPPDATA%\RetroRewind\Saved\
  Crashes since t whose CrashContext.runtime-xml <ProcessId> matches), rt_pid, rt_pid_alive (a
  running process with this exe's name). Native tests cover all three.
- safety.lua: records carry the pid; EVERY ended record is judged (not only the claimed slot)
  and cleared; uncertain verdicts (probation / phase-only) wait for Safety.settle(crashesSince,
  pidAlive), called by main.lua right after the native load: no report -> not a crash; report ->
  blamed; unknown -> blamed as before unless the record was closed in order. A fresh record
  whose pid is dead is judged too (a copy killed and relaunched within 10 s - measured 7-8 s).
- Live: window closed with the stand-in on probation -> "stopped without crashing"; killed and
  relaunched 8 s later -> same, killed record cleared; real crash (string for ClientMessage's
  FName, AV at 0x70, report pid 63400) -> reported against its bridge phase, stand-in not
  blamed. A crashed process that hangs after writing its report keeps counting as running.

### Posters, NPC speech, level-up unlocks on a guest (2026-10-15)
- Posters: PosterFrame_C (+ _Standing, _Small) "Specific SKU" is a plain BP int, set by Load or
  the SKU menu; Apply Material for Film based on SKU (@4081) calls Film_Data Create Film Data,
  which with SKU 0 rolls a random film. The skins' Materials Loaded runs it on a guest with 0.
  skinsync now sends "posters" (place;yaw;sku) beside titles/signs. Live: 4/4 frames the same
  SKU and title on both; a guest frame set to 0 rolled 10463373 and was back to 1794141 within
  the 10 s re-check; "They Came for the Inmate" on both screenshots.
- Speech: Widget3D_AiSpeakInWorld (screen space, under Head_Socket) filled only by AI_Base
  "AI Talk about a problem" / "AI Toggle a permanent problem" (callers: AI tasks, CheckOut,
  BlackMarket, flyers). Host RegisterHook on both (re-hooked when the UFunction's address
  changes), queue, "npct" from the tick; guest: widget's Set Text and Show Message (or the NPC's
  own event when a sound path comes along), Set Text And Show Message Permanent / Start
  Animation Hidden Message. No natural line in ~2 min of open store; the host called a
  customer's own event (nil sound, as the replay passes nil object params): the guest's copy at
  1568,-1260 showed the same words at opacity 1.0, both screenshots.
- Unlocks: UI_EndOfTheDay "Add Widgets For Level Unlock and Unlock it" runs from the XP
  animation (GameMode-only). dayend sends u=system.movie.game per child; the guest Creates
  UI_Statistic_Levelup_Unlock_C, SetBytePropertyByName x3, AddChildToHorizontalBox; a movie genre
  also gets UI_GenreUnlock_C at z 12. Live: XP +300 (7112 -> 7414, level 11 -> 12 at 7300),
  clock to 19:58, sign closed, door Interaction once customers left, UX_Button_Base event ->
  level 12 "Cotton Candy Machine" + "Repair Desk" (4.0.0, 15.0.0) on both; second day +750 ->
  level 13 "Kid" (0.12.0), genre popup made on both and gone on both by the next look.
- User report mid-test: "there is also no guest pawn". Host's copy of the guest at 2495,41,94 in
  MovementMode 3 (the join placement), the guest at 1356,-1352: aim.py teleports the client only,
  and with the server not correcting the client nor taking its position, nothing converges.
  Moved the host's copy by hand for the test; window key input never reached the guest copy, so
  bServerAcceptClientAuthoritativePosition could not be tried with real moves. Proposed as a
  follow-up.

### Conversations, NPC shaking, a guest who could not walk (2026-10-15, overnight)
- Conversations: talksync.lua. TalkSystem_C is spawned on the host for GetPlayerPawn(0) during a
  guest's replayed click (= the guest's pawn); BeginPlay draws UI_Talk_C into the HOST's viewport
  and runs a 0.5 s camera timeline on GetPlayerPawn(0) (the host). Hook on ReceiveBeginPlay (post):
  Force Stop LookAt + RemoveFromParent; host reads txt_talk/txt_NameClient/Zone_ButtonAnswer and
  sends "talk"; guest builds UI_Talk_C + UI_Talk-Answer_C (Answer Type/Button Text/Number Text),
  UI input + cursor; hook on UI_Talk-Answer_C:Button Clicked Event -> action 11 (Pitch = type);
  host clicks the hidden widget's "Clicked on Answer Button Event" as the guest. End Talk System
  hook / actor gone -> "talk e=1". Guest gone -> answer 1 (Quit). Live: Adam's 4 answers on the
  guest only, host camera untouched, "Never mind" closed both; guest killed mid-talk -> the host's
  talk ended once its controller went, Adam back to task 2/3.
- Sampling NPCs per frame from the dev bridge: StaticFindObject by full path inside a ReceiveTick
  hook took the guest to 2.5 fps (and leftover hooks keep running - use a new global per sampler).
  Resolving once inside the hook and reusing: ~70 fps.
- NPC shaking: a customer at (915,-1735) on the guest: capsule z 90 <-> 116..119 every other frame,
  mesh z up to 101 - stepping onto something the host did not have. Actors near: the guest had two
  sets of the snack display's SnackBox_Snack_C / UISelect triggers / rotating meshes; the extra set
  (role SimulatedProxy, the host's replicated child actors, their children spawned locally) had
  trigger collision on. "SnackBox" in Config.ReplicatedClasses; all 4 instances are child actors.
  Hand-disabling the extra set: a customer 10 units from a trigger walked level. Fix: never
  replicate child actors (switch off if replicating). SetReplicates(false) did NOT remove the
  guest's existing copies; a fresh session has none (4/8/4 on both).
- "No guest pawn" -> a guest that could not walk: the guest's own pawn had role 1 (SimulatedProxy)
  on the guest, RemoteRole 1 on the host. UE 5 SetReplicates(true) calls
  SetRemoteRoleForBackwardsCompat(SimulatedProxy) every time; the sweep called it on the already-
  replicating pawn. AddMovementInput and window W did nothing; LaunchCharacter moved it (simulated).
  RemoteRole = 2 written on the host (SetAutonomousProxy is not reflected): the guest walked and the
  host's copy followed. With bServerAcceptClientAuthoritativePosition too, the host's copy ended
  exactly on the guest (1300,-1312). That broke the join placement (both left at 2367,177,-408):
  server-side moves never reach a trusted client - Replication.beforeHostMovesGuest untrusts for
  1.5 s, the engine's ClientAdjustPosition carries the move, restoreTrust re-trusts.
- Final build, regression on two copies: join (autonomous, placed 2495,41 on both, trust back),
  walk 311 units + jump (same spot on both), both bodies visible, rt.bring, till enter/exit (exit
  fix on the guest's own pawn, same spot on both), tape off a shelf and back, build mode (placed
  at the preview spot), conversation, customers past the snack display (mesh steady).
- Sprint check (guest's own position every frame via a ReceiveTick hook, MaxWalkSpeed = Run Speed
  550 on the guest only, AddMovementInput each frame, 150 frames): both flags on -> moved 994,
  2 reversals under 1 unit, host's copy at the guest's spot (1501,67); control with the host's
  corrections on (both flags false) -> moved 744, 33 reversals up to 84.9 units.
- Review fixes (code review of all of the above): guest conversation closes after 10 s without
  word from the host (host resends every 3 s); a departed guest's talk is quit only while the host
  is walking (End Talk System resets player 0 = the host); "talk ended" retried until sent; NPC
  speech not queued with no guest connected, permanent lines tracked regardless; trust window 5 s
  (corrections only answer a guest's move); no class-default patch for a class with child-actor
  instances; a failed unlock fill is retried; conversation answers are taken during the summary.
- Last sanity run (final code): join placement on both, trust back, walk followed exactly,
  conversation open past 5 s, answered, closed. Then a dev probe (FindFirstOf("TalkSystem_C") on
  a destroyed talk + HasAnyFlags) crashed the host - probe only; the mod finds talks by path and
  checks UE.alive (object-array flags) first. Records deleted, saves unchanged (6677069f).
- Launcher one-click setup (user: "make the launcher handle all the stuff for people so installing
  rewind together is stupid simple"). Core/SetupPlan.cs decides UE4SS / install-or-update / switch
  on; MainViewModel.SetUpAsync runs it when the launcher opens, when the game closes, before
  HOST/JOIN, and from the Setup line's single button. A running game: asked once, closed with
  CloseMainWindow (never killed). The release zip now carries the pinned UE4SS zip
  (Mods/UE4SS/, sha-checked by package.py and again by the launcher) and its MIT LICENSE; the port
  tools moved to Extras/ (mod messages updated). 181 launcher tests pass. Checked through UI
  Automation on fake game folders only: fresh install with no download, 1.6.1 -> 1.7.0 keeping
  config.lua, switched-off left alone then switched on, stand-in game closed by the launcher and
  by hand, exe run alone from %TEMP% -> "Unzip the download first". The real game was not touched.
- Real-game close check (user OK; one copy via Steam; saves backed up and byte-identical after,
  GameUserSettings.ini restored from .pre-claude, UE4SS-settings.ini restored byte-identical).
  WM_CLOSE from outside: game quits in 1.6 s (main menu) / 1.4 s (in the store, Sun 8:00), DLLs
  free at once, crash guard record "idle (between ticks)", nothing disabled. Found: with UE4SS's GUI
  console shown (1.6's installer set GuiConsoleVisible = 1; the launcher keeps that file),
  Process.MainWindowHandle is the console, and CloseMainWindow closed only the console - the game
  kept running. GameProcess.CloseAsync now posts WM_CLOSE to the visible "UnrealWindow" of the
  process (fallback CloseMainWindow). Verified through CloseAsync itself on the real game with the
  console in front: closed in 2.4 s. Stand-in fallback rechecked on the final exe. Zip rebuilt.
  Note: the pinned UE4SS's default ini has no console at all (ConsoleEnabled = 0,
  GuiConsoleEnabled = 0), so friends on a fresh launcher install have no window for rt.* commands.
- No UE4SS window on fresh installs (user chose: no extra window, point docs at the game's
  console). The pinned UE4SS ini has ConsoleEnabled = 0 / GuiConsoleEnabled = 0, but its
  ConsoleEnablerMod (on) gives the game's own console on ~, # and F10, and rt.* commands
  (RegisterConsoleCommandHandler) print into it via the output device. Checked on the real game
  at the main menu: F10 once = one-line console, twice = full console, three times = closed;
  rt.status ran and its report showed in the full console. (Typing into the full console through
  WinDrivePid kept dropping keys - a driver quirk; UE's full console stays open after Enter.)
  FRIEND guide, README, VERSION.txt, release-notes draft and mod messages (commands.lua header,
  config.lua comments, spawn.lua rt.fixpawns hint, mainmenu.lua warning) now say "press ~ twice".
  F6 still only writes to the log while SafeMode is on. Zip rebuilt; saves unchanged, settings
  restored. Not deployed to the real game's mod folder.
- F6 visible without the UE4SS window. UConsole reflects nothing (CXXHeaderDump), so the game's
  console can't be opened from Lua; instead Commands.showStatus -> Hud.notice puts a 3-line status
  in the HUD's UI_Error box (Display Error(FString), "{br}" breaks, Animation Time raised to 800
  ticks = 8 s) whenever the overlay is off (SafeMode default). Overlay.isEnabled added. Smoke: 5
  checks (no HUD, notice text/colour, return value, 8 s, overlay on). Real game (user OK; saves
  unchanged, GameUserSettings.ini restored, bridge files removed): F6 at the menu logs only; in the
  store the real key shows the centred box; timer measured 268 ticks after ~2.7 s of 800. Deployed
  hud.lua/overlay.lua/commands.lua (only this session's changes differed). Gotcha in PROJECT.md.
- Launcher, for 1.7.1 (uncommitted until released):
  - Self-update from GitHub releases (Core\SelfUpdate.cs): banner + Update, SHA-256 checked,
    swap with rollback, restart keeping --data-dir/--game-dir. End to end against a stand-in
    GitHub on 127.0.0.1: about 14 s.
  - Mod check before joining (Core\ModFingerprint.cs): the host publishes rt_ver/rt_cmods/
    rt_cnames/rt_smods/rt_snames in Steam rich presence. The guest's friend list and JOIN say
    what differs, with "Join anyway". Unit-tested with simulated Steam data only; not yet tried
    with two real accounts.
  - Discord status (Core\DiscordPresence.cs): local RPC pipe, application "Rewind Together" (id
    1560334255547093155, art asset "logo"). Real Discord accepted the activity (name "Rewind
    Together", logo resolved, button URL attached) from a throwaway console using the launcher's
    own classes; the status was cleared afterwards. Set for the game's pid. Not yet seen with
    the real game running: whether Discord then hides its own "Playing Retro Rewind" is
    unconfirmed.
  - Logo: launcher\tools\make-wordmark.py draws the REWIND TOGETHER sticker (RT pink/cyan, purple
    die-cut outline) to dist\discord\logo-wordmark.png.
  - 223 launcher tests, 5 clean runs in a row.
