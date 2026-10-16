--[[
    Rewind Together - engine access helpers

    Everything that reaches into the running game goes through here, so that
    when a game patch moves something we only have to fix one file.

    Nothing in this file assumes an object exists. The game is a shipping
    build; objects come and go across level travel and every accessor
    re-resolves rather than caching across worlds.
]]

local Log = require("log")

local UE = {}

-- Blueprint classes are cooked with a _C suffix; these are the paths we care about.
UE.Paths = {
    PlayerCharacter   = "/Game/VideoStore/core/pawn/Player_Character.Player_Character_C",
    PlayerCharacterCDO= "/Game/VideoStore/core/pawn/Player_Character.Default__Player_Character_C",
    PlayerController  = "/Game/VideoStore/core/input/Core_Player_Controller.Core_Player_Controller_C",
    GameMode          = "/Game/VideoStore/core/gamemode/Core_Gamemode.Core_Gamemode_C",
    GameInstance      = "/Game/VideoStore/core/gamemode/Core_GameInstance.Core_GameInstance_C",
    LobbyMap          = "/Game/VideoStore/core/level/L_Multiplayer_Lobby",
}

--------------------------------------------------------------------------
-- Core object accessors
--------------------------------------------------------------------------

--- Is this a live UObject?
---
--- Tolerates anything, including the `false` sentinel the per-frame cache
--- stores for "looked this up, found nothing" - indexing that would throw and
--- take down whichever callback was running.
local function valid(o)
    if o == nil or o == false then return false end
    if type(o) ~= "table" and type(o) ~= "userdata" then return false end
    local ok, result = pcall(function()
        return o.IsValid ~= nil and o:IsValid()
    end)
    return ok and result == true
end
UE.valid = valid

--- Is this object safe to CALL INTO, as opposed to merely present?
---
--- valid() answers "is there a UObject at this address". That is a weaker
--- question than it looks, and the difference has cost this project a crash.
--- When a guest goes away the engine tears their PlayerController down over
--- several frames: the UNetConnection is dropped, the actor is flagged as
--- garbage, and FindAllOf keeps handing it back until the object slot is
--- reused. Through that window it is indistinguishable from a guest who needs
--- a pawn - they have no pawn, because theirs was just unpossessed - and
--- calling a GameMode login function with it reaches into memory that is being
--- freed. pcall does not save you there; it traps Lua errors, not memory
--- faults.
---
--- The evidence: 01:05:04 the guest's controller reported no pawn while their
--- character stood in the world unpossessed, 01:05:08 the ladder fired
--- HandleStartingNewPlayer at it, and the next line in the log is a fresh
--- session twelve seconds later with no error logged by anyone.
---
--- Two tests, either of which is enough:
---   * AActor::IsActorBeingDestroyed - an actor announcing its own teardown.
---     This is the one that catches our case: a departing player's controller
---     has had Destroy() called on it,
---   * the raw internal flags, which is the test UE4SS's own bundled
---     SplitScreenMod uses to skip controllers that are on their way out.
---
--- Deliberately NOT UKismetSystemLibrary::IsValid, which would be the obvious
--- choice and does not work here: UE4SS's built-in UObject members shadow
--- reflected UFunctions of the same name, so `ksl:IsValid(obj)` dispatches to
--- the built-in, ignores the argument entirely, and answers "is the
--- KismetSystemLibrary itself valid" - which is always yes. It would have been
--- a no-op wearing the costume of a safety check.
---
--- Both tests FAIL OPEN: each only ever reports death on a positive signal, so
--- with neither available alive() is exactly valid() and behaviour is what it
--- was before. That direction is deliberate. Missing a teardown costs the rare
--- crash above; a false negative would make every guest look like they were
--- leaving, switching the spawn ladder off permanently and putting everyone
--- back on a black screen. Those are not the same mistake.
function UE.alive(obj)
    if not valid(obj) then return false end

    local ok, dying = pcall(function() return obj:IsActorBeingDestroyed() end)
    if ok and dying == true then return false end

    -- UE5.4 renamed PendingKill to Garbage; which one this UE4SS build
    -- publishes is a property of the build, so try both and ignore a miss.
    if EInternalObjectFlags ~= nil then
        for _, flagName in ipairs({ "PendingKill", "Garbage" }) do
            local flag = EInternalObjectFlags[flagName]
            if flag ~= nil then
                local ok2, has = pcall(function() return obj:HasAnyInternalFlags(flag) end)
                if ok2 and has == true then return false end
            end
        end
    end

    return true
end

--- Are these two references the same engine object?
---
--- Do NOT use `a == b` for this. UE4SS hands back a fresh Lua wrapper for each
--- lookup, so two references to one actor can compare unequal - measured:
--- rt.why labelled the local player's own pawn "OTHER PLAYER" alongside the
--- real one, because `p == UE.GetPawn()` was false for the pawn it had just
--- got FROM GetPawn. Left unfixed that would have had bodies.lua put a
--- borrowed body inside its own camera.
---
--- Full names are unique per object and stable for its lifetime, which is the
--- same property the rest of this codebase already keys its bookkeeping on.
function UE.sameObject(a, b)
    if a == b then return true end          -- cheap, and right when it hits
    if not (valid(a) and valid(b)) then return false end
    local an, bn
    local ok = pcall(function()
        an = a:GetFullName()
        bn = b:GetFullName()
    end)
    return ok and an ~= nil and an == bn
end

--------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------

--- Render an engine value as a real Lua string.
---
--- FString, FName and FText properties come back from this build as userdata,
--- not as Lua strings, and tostring() on one yields "FString: 000001305A8CD158".
--- That is not a hypothetical: it is what the pawn diagnosis printed where a
--- player's name should have been, what rt.players listed, what the net driver
--- summary showed instead of a driver name, and what every chat message was
--- stamped with as its sender.
function UE.ToStr(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "string" then return v end
    if t == "number" or t == "boolean" then return tostring(v) end

    -- Every string-ish engine type exposes ToString(); a UObject that does not
    -- simply falls through to tostring() as before.
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" and s ~= "" then return s end
    return tostring(v)
end

--- A player's display name, from either a PlayerState or a PlayerController.
--- Returns nil rather than a placeholder so callers can say "unknown" in
--- whatever wording suits them.
function UE.PlayerNameOf(obj)
    if not valid(obj) then return nil end

    local ps = obj
    -- A controller: go via its state.
    local maybe = UE.TryGet(obj, "PlayerState")
    if valid(maybe) then ps = maybe end

    for _, prop in ipairs({ "PlayerNamePrivate", "PlayerName" }) do
        local s = UE.ToStr(UE.TryGet(ps, prop))
        -- Reject the userdata-address form outright: a name that reads
        -- "FString: 0000..." is worse than no name, because it looks like data.
        if s and s ~= "" and not s:find("^%u%a+: %x+$") then return s end
    end
    return nil
end

--------------------------------------------------------------------------
-- Finding things
--------------------------------------------------------------------------
-- MEASURED in 1.7.0, on a host with a full store: UE4SS's FindAllOf and
-- FindFirstOf walk the whole UObject array - 15-17 ms a call whatever the
-- class, hit or miss - and StaticFindObject takes 1-2 ms. Between the modules
-- that came to about 40 walks a second: the mod spent 60% of the host's game
-- thread (53% of the guest's) inside them, a frame-rate cost every player
-- paid.
--
-- The engine answers the same questions from its own indexes:
--   * world, game mode, game state, player controllers: the GameInstance and
--     GameplayStatics, in microseconds;
--   * a loaded class or asset from its path: KismetSystemLibrary's
--     soft-reference helpers, 0.02 ms;
--   * every actor of a class: GameplayStatics.GetAllActorsOfClass, 479 tapes
--     in 4 ms (nearly all of it building the Lua wrappers), and the first one
--     with GetActorOfClass, 0.008 ms.
--
-- GetAllActorsOfClass has two catches, both read off UE4SS's source at the
-- build this mod pins (0196ef29, LuaUObject.cpp call_ufunction_from_lua):
--   * the out-table's elements are RemoteUnrealParam references into the
--     engine's result array, not actors - each needs :get() (measured: used
--     directly, every one failed IsValid and nothing was ever patched);
--   * that result array lives in a stack buffer UE4SS never destroys, so the
--     engine's allocation for it is never freed: 8 bytes per actor returned,
--     per call. Which is also why reading it afterwards is safe. Callers that
--     list big classes do it every few seconds, not every tick.
--
-- Kept across frames, and nothing else: the GameInstance, the engine and the
-- library default objects, each of which lives exactly as long as the
-- process. Classes are remembered by PATH, a string.
--
-- Everything else resolved during a tick is cached until the tick ends
-- (main.lua calls beginFrame and endFrame) and never used after it: garbage
-- collection runs between frames, and an object found in one frame can be
-- gone in the next.

local cache = {}
local frameOpen = false
-- UE4SS's own, kept before StaticFindObject is replaced (below UE.findObject).
local realStaticFindObject = StaticFindObject
local lastTickPc = nil   -- only for the test harness; see peekPlayerController

--- Outside a tick nothing is remembered, so a lookup made from the key poll
--- or a hook can never hand a later frame an object that frame never saw.
local function frame()
    if not frameOpen then cache = {} end
end

local function copy(list)
    local t = {}
    for i = 1, #list do t[i] = list[i] end
    return t
end

local roots = {}
local giRetryAt = 0
local worldAddr = nil

-- What the lookups cost, for rt.status: engine calls that allocate memory
-- which is never freed (see below), and walks of the whole object array.
local stats = { objects = 0, lists = 0, listed = 0, walks = 0 }

function UE.lookupStats()
    return { objects = stats.objects, lists = stats.lists, listed = stats.listed,
             walks = stats.walks, refs = UE._softRefCount and UE._softRefCount() or 0 }
end

local function libraryDefault(key, path)
    local o = roots[key]
    if o ~= nil and valid(o) then return o end
    o = realStaticFindObject(path)
    if valid(o) then
        roots[key] = o
        return o
    end
    return nil
end

local function statics() return libraryDefault("gs", "/Script/Engine.Default__GameplayStatics") end
local function kismet()  return libraryDefault("ksl", "/Script/Engine.Default__KismetSystemLibrary") end

local function gameInstance()
    local gi = roots.gi
    if gi ~= nil and valid(gi) then return gi end
    roots.gi = nil
    local t = os.clock()
    if t < giRetryAt then return nil end
    giRetryAt = t + 2
    -- The one walk this file makes on purpose: once per process.
    for _, o in ipairs(FindAllOf("GameInstance") or {}) do
        local name = nil
        pcall(function() name = o:GetFName():ToString() end)
        if valid(o) and type(name) == "string" and not name:find("^Default__") then
            roots.gi = o
            return o
        end
    end
    return nil
end

--- GameplayStatics, and a GameInstance to pass it as the world context. The
--- game always has both; the test harness runs without them, which keeps the
--- walking fallbacks below covered.
local function engineRoute()
    local gs = statics()
    if not gs then return nil end
    local gi = gameInstance()
    if not gi then return nil end
    return gs, gi
end

--[[
    SOFT REFERENCES, KEPT. Resolving a path through KismetSystemLibrary is three
    calls; MEASURED (15 Oct 2026, 200,000 calls each, the control 0-1 bytes):
      MakeSoftObjectPath + Conv_SoftObjPathToSoftObjRef + Conv_..ToObject  257 bytes a call
      Conv_SoftObjectReferenceToObject alone, on a kept reference          86 bytes a call
    never freed by UE4SS - so every class looked up once per tick (UE.findAll,
    UE.findFirst: ~13 a second on a host with one guest) leaked ~12 MB an hour.
    A TSoftObjectPtr is a VALUE - a weak pointer plus the path - and is safe to
    keep where an object pointer is not (PROJECT.md 5): resolving it checks the
    weak pointer against the object array's serial number, so a freed object is
    never handed back, and a stale one is looked up by path again. Measured:
    kept references stay independent (A, then B, then 50 more: A still A) and
    resolve the same in a later frame. So each path's reference is made once.
]]
local softRefs, softCount, SOFT_MAX = {}, 0, 512
function UE._softRefCount() return softCount end

local function softRefOf(ksl, path)
    local r = softRefs[path]
    if r ~= nil then return r end
    -- A bound, not an eviction policy: the mod looks up a few dozen paths.
    if softCount >= SOFT_MAX then softRefs, softCount = {}, 0 end
    r = ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(path))
    if r ~= nil then
        softRefs[path] = r
        softCount = softCount + 1
    end
    return r
end

--- A loaded object from its path - an asset, a class, a placed actor -
--- without loading anything and without StaticFindObject's 1-2 ms. nil when
--- it is not in memory.
---
--- MEASURED cost besides the 0.03 ms: about 0.6 KB that is never freed, per
--- call (100,000 calls: +124 MB over two runs, a struct-free control +19).
--- The path goes in as an FString, built in the parameter block UE4SS never
--- destroys (see GetAllActorsOfClass above). So each path is looked up at
--- most once per tick, and native classes - which never unload - only once.
function UE.findObject(path)
    if type(path) ~= "string" or path == "" then return nil end
    frame()
    local key = "O:" .. path
    local hit = cache[key]
    if hit ~= nil then
        if hit and valid(hit) then return hit end
        return nil
    end
    local o = nil
    local ksl = kismet()
    local ok = false
    if ksl then
        if UE.trace then UE.trace("findObject", path) end
        stats.objects = stats.objects + 1
        ok = pcall(function() o = ksl:Conv_SoftObjectReferenceToObject(softRefOf(ksl, path)) end)
    end
    -- MEASURED: a path that is not loaded comes back as a wrapper around
    -- nullptr, not as nil.
    if not ok then o = realStaticFindObject(path) end
    if not valid(o) then o = nil end
    cache[key] = o or false
    return o
end

--[[
    StaticFindObject, WITHOUT THE WALK.

    MEASURED (15 Oct 2026, on the host): UE4SS's StaticFindObject takes 11 ms
    a call. It is UE4SS's own FindObject - a walk over every object in the
    engine - where UE.findObject (above) finds the same object in 0.1 ms; ten
    kinds of path compared (library defaults, native and Blueprint classes, a
    Blueprint function, a placed actor, a missing path): the same answer every
    time. The host crashed twice with three players inside exactly that walk
    (UE4SS UObjectGlobals::FindObject -> ForEachUObject -> UObject::GetOutermost,
    reading through an object that was going away), each time in a tick phase
    that calls StaticFindObject on a timer (NpcSync.tickHost: its speech hooks,
    every 5 s; World.tickHost: the sky). Fifty-odd calls in this mod, a few of
    them every few seconds for good.

    So the global is replaced, for every module at once. The engine's own
    classes and library defaults never unload, so those are kept; anything
    else is looked up each time. The walk is only the fallback for a path the
    soft-path route could not take at all (no KismetSystemLibrary yet).
]]
local forever = {}           -- "/Script/..." path -> object: never unloads

--- The soft-path route alone: ok is false when it could not be taken.
local function softResolve(path)
    local ksl = kismet()
    if not ksl then return false, nil end
    local o = nil
    local ok = pcall(function() o = ksl:Conv_SoftObjectReferenceToObject(softRefOf(ksl, path)) end)
    if not ok then return false, nil end
    stats.objects = stats.objects + 1
    if not valid(o) then o = nil end
    return true, o
end

function UE.staticFind(path)
    if type(path) ~= "string" or path == "" then return realStaticFindObject(path) end
    local kept = forever[path]
    if kept ~= nil and valid(kept) then return kept end
    local ok, o = softResolve(path)
    if not ok then return realStaticFindObject(path) end
    if o ~= nil and path:sub(1, 8) == "/Script/" then forever[path] = o end
    return o
end
if realStaticFindObject ~= nil then _G.StaticFindObject = UE.staticFind end

--- An object's path, to find it again in a later frame with UE.findObject
--- (0.03 ms, measured on the guest's HUD widget). That is how to remember an
--- object across frames: by name, never by a pointer garbage collection can
--- free. nil for anything that is not a live object.
function UE.pathOf(obj)
    if not valid(obj) then return nil end
    local full = nil
    pcall(function() full = obj:GetFullName() end)
    if type(full) ~= "string" then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

-- Where the classes this mod looks for live, measured on game build
-- 23896268, so the lookups it makes every tick never walk. A path a game
-- update moves just stops resolving, and the class is then learned from a
-- live object of it instead.
local KNOWN_CLASSES = {
    Player_Character_C        = "/Game/VideoStore/core/pawn/Player_Character.Player_Character_C",
    Core_Player_Controller_C  = "/Game/VideoStore/core/input/Core_Player_Controller.Core_Player_Controller_C",
    Core_Gamemode_C           = "/Game/VideoStore/core/gamemode/Core_Gamemode.Core_Gamemode_C",
    WeatherSystem_C           = "/Game/VideoStore/asset/outside/WeatherSystem.WeatherSystem_C",
    StoreName_C               = "/Game/VideoStore/asset/prop/StoreName/StoreName.StoreName_C",
    StoreExpansion_C          = "/Game/VideoStore/core/blueprint/research/StoreExpansion/StoreExpansion.StoreExpansion_C",
    NavCollisionZone_C        = "/Game/VideoStore/core/blueprint/class/NavCollisionZone.NavCollisionZone_C",
    AI_WalkBy_Character_C     = "/Game/VideoStore/core/ai/pawn/AI_WalkBy_Character.AI_WalkBy_Character_C",
    AI_Client_Character_C     = "/Game/VideoStore/core/ai/pawn/AI_Client_Character.AI_Client_Character_C",
    AI_Employee_Character_C   = "/Game/VideoStore/core/ai/pawn/AI_Employee_Character.AI_Employee_Character_C",
    AI_BackAlleyVendor_Character_C =
        "/Game/VideoStore/core/ai/pawn/AI_BackAlleyVendor_Character.AI_BackAlleyVendor_Character_C",
    AI_Base_Character_C       = "/Game/VideoStore/core/ai/pawn/AI_Base_Character.AI_Base_Character_C",
    PickupActor_C             = "/Game/VideoStore/core/blueprint/PickupActor.PickupActor_C",
    MovableActor_C            = "/Game/VideoStore/core/blueprint/MovableActor.MovableActor_C",
    Cartridge_Base_C          = "/Game/VideoStore/asset/prop/vhs/Cartridge_Base.Cartridge_Base_C",
    MovingBox_C               = "/Game/VideoStore/asset/prop/movingbox/MovingBox.MovingBox_C",
    Shelve_C                  = "/Game/VideoStore/asset/prop/shelve/Shelve.Shelve_C",
    Shelve_Container_C        = "/Game/VideoStore/asset/prop/shelve/Shelve_Container.Shelve_Container_C",
    BoxStorage_Container_C    = "/Game/VideoStore/asset/prop/shelve/BoxStorage_Container.BoxStorage_Container_C",
    SnackBox_C                = "/Game/VideoStore/asset/prop/Snack/SnackBox.SnackBox_C",
    SnackShelf_C              = "/Game/VideoStore/asset/prop/Snack/SnackShelf.SnackShelf_C",
    Storage_Box_C             = "/Game/VideoStore/asset/prop/Storage/Storage_Box.Storage_Box_C",
    Storage_Cartridge_C       = "/Game/VideoStore/asset/prop/Storage/Storage_Cartridge.Storage_Cartridge_C",
    Decoration_C              = "/Game/VideoStore/asset/prop/decoration/Decoration.Decoration_C",
    -- skinsync.lua: the base classes of everything with an AC_MeshSkin.
    Wall_C                    = "/Game/VideoStore/asset/prop/wall/Wall.Wall_C",
    ShelveTitle_C             = "/Game/VideoStore/asset/prop/shelve/ShelveTitle.ShelveTitle_C",
    Arcade_C                  = "/Game/VideoStore/asset/prop/arcade/Arcade.Arcade_C",
    CandyDispenser_Base_C     = "/Game/VideoStore/asset/prop/CandyDispenser/CandyDispenser_Base.CandyDispenser_Base_C",
    -- The rest of Config.ReplicatedClasses (pak listing), so none is learned by a walk.
    Snack_Pack_4x_C           = "/Game/VideoStore/asset/prop/Snack/Snack_Pack_4x.Snack_Pack_4x_C",
    PosterFrame_C             = "/Game/VideoStore/asset/prop/PosterFrame/PosterFrame.PosterFrame_C",
    Standees_C                = "/Game/VideoStore/asset/prop/Standees/Standees.Standees_C",
    TextSign_C                = "/Game/VideoStore/asset/prop/decoration/TextSign/TextSign.TextSign_C",
    Door_C                    = "/Game/VideoStore/asset/prop/Door/Door.Door_C",
    BP_Television_BASE_C      = "/Game/VideoStore/asset/prop/TV/BP_Television_BASE.BP_Television_BASE_C",
    Staff_C                   = "/Game/VideoStore/asset/prop/StaffBook/Staff.Staff_C",
    ["ConsoleRental_Console-Base_C"] =
        "/Game/VideoStore/asset/prop/ConsoleRental/ConsoleRental_Console-Base.ConsoleRental_Console-Base_C",
    -- guestinput.lua: the till, and every other machine (the computer, the
    -- catalogue, the return desk...: eighteen subclasses of MachineActor_C).
    MembershipMachine_C       = "/Game/VideoStore/asset/prop/CheckOut/MembershipMachine.MembershipMachine_C",
    MachineActor_C            = "/Game/VideoStore/core/blueprint/MachineActor.MachineActor_C",
    -- A machine's hold-and-drag steps (machines.lua).
    ["Cursor-Movement_Distance_C"] = "/Game/VideoStore/core/blueprint/cursor-movement/Cursor-Movement_Distance.Cursor-Movement_Distance_C",
    -- The return desk's parts (mirror.lua finds the guest's copies).
    Return_C               = "/Game/VideoStore/asset/prop/Return/Return.Return_C",
    Rewinder_C             = "/Game/VideoStore/asset/prop/Rewinder/Rewinder.Rewinder_C",
    DropBox_C              = "/Game/VideoStore/asset/prop/DropBox/DropBox.DropBox_C",
    Scanner_Dropbox_C      = "/Game/VideoStore/asset/prop/DropBox/Scanner_Dropbox.Scanner_Dropbox_C",
    Scanner_Checkout_C     = "/Game/VideoStore/asset/prop/DropBox/Scanner_Checkout.Scanner_Checkout_C",
    videotape_FullDetail_C = "/Game/VideoStore/asset/prop/vhs/videotape_FullDetail.videotape_FullDetail_C",
    MoviePlayer_C          = "/Game/VideoStore/asset/prop/MoviePlayer/MoviePlayer.MoviePlayer_C",
    -- What listens for the time of day (worldsync.lua): two components, three actors.
    Light_DayTimeToggle_C  = "/Game/VideoStore/asset/lighting/Light_DayTimeToggle.Light_DayTimeToggle_C",
    VFX_DayTimeToggle_C    = "/Game/VideoStore/asset/lighting/VFX_DayTimeToggle.VFX_DayTimeToggle_C",
    Outside_Light_Base_C   = "/Game/VideoStore/asset/lighting/Outside_Light_Base.Outside_Light_Base_C",
    Audio_TimeOfDay_C      = "/Game/VideoStore/core/sfx/AmbienceSystem/Audio_TimeOfDay.Audio_TimeOfDay_C",
    Audio_AmbienceSystem_C = "/Game/VideoStore/core/sfx/AmbienceSystem/Audio_AmbienceSystem.Audio_AmbienceSystem_C",
    -- Machines the host buys (worldsync.lua makes them usable on guests).
    PopcornMachine_C        = "/Game/VideoStore/asset/prop/Popcorn/PopcornMachine.PopcornMachine_C",
    SlushMachine_C          = "/Game/VideoStore/asset/prop/Slush/SlushMachine.SlushMachine_C",
    CottonCandyMachine_C    = "/Game/VideoStore/asset/prop/CottonCandy/CottonCandyMachine.CottonCandyMachine_C",
    ConsoleRental_Mat_C     = "/Game/VideoStore/asset/prop/ConsoleRental/ConsoleRental_Mat.ConsoleRental_Mat_C",
    ConsoleRental_Station_C = "/Game/VideoStore/asset/prop/ConsoleRental/ConsoleRental_Station.ConsoleRental_Station_C",
    CustomMovieStation_C    = "/Game/VideoStore/asset/prop/CustomMovieStation/CustomMovieStation.CustomMovieStation_C",
    RepairStation_C         = "/Game/VideoStore/asset/prop/RepairStation/RepairStation.RepairStation_C",
    SidewalkSign_C          = "/Game/VideoStore/asset/prop/SidewalkSign/SidewalkSign.SidewalkSign_C",
    SnackShelf_C            = "/Game/VideoStore/asset/prop/Snack/SnackShelf.SnackShelf_C",
    -- concessions.lua: what the concession machines make.
    PopcornCup_C            = "/Game/VideoStore/asset/prop/Popcorn/PopcornCup.PopcornCup_C",
    SlushCup_C              = "/Game/VideoStore/asset/prop/Slush/SlushCup.SlushCup_C",
    CottonCandy_Stick_C     = "/Game/VideoStore/asset/prop/CottonCandy/CottonCandy_Stick.CottonCandy_Stick_C",
    -- computer.lua: the office computer, and the market it sells from.
    ComputerScreen_C          = "/Game/VideoStore/asset/prop/Computer/ComputerScreen.ComputerScreen_C",
    Market_C                  = "/Game/VideoStore/core/blueprint/Market.Market_C",
    CheckOut_C                = "/Game/VideoStore/asset/prop/CheckOut/CheckOut.CheckOut_C",
    -- npcsync.lua: a guest's own AI Director, stopped.
    AI_Director_C             = "/Game/VideoStore/core/blueprint/AI_Director.AI_Director_C",
    PosterFrame_C             = "/Game/VideoStore/asset/prop/PosterFrame/PosterFrame.PosterFrame_C",
    Standees_C                = "/Game/VideoStore/asset/prop/Standees/Standees.Standees_C",
    TextSign_C                = "/Game/VideoStore/asset/prop/decoration/TextSign/TextSign.TextSign_C",
    Door_C                    = "/Game/VideoStore/asset/prop/Door/Door.Door_C",
    BP_Television_BASE_C      = "/Game/VideoStore/asset/prop/TV/BP_Television_BASE.BP_Television_BASE_C",
    Wall_C                    = "/Game/VideoStore/asset/prop/wall/Wall.Wall_C",
}

local classInfo    = {}  -- short name -> { path = "...", actor = bool }
local classRetryAt = {}  -- short name -> when to try learning it again
local classBackoff = {}  -- short name -> the wait after the next miss, seconds
local LEARN_FIRST_WAIT, LEARN_MAX_WAIT = 5, 60
-- Every try to learn a class is a walk of the whole object array (FindFirstOf),
-- the operation the host crashed inside (see UE.staticFind). MEASURED: eight
-- names in Config.ReplicatedClasses that this game does not have (AI_Character,
-- Staff, Customer, Snack_Pack_4x ...) were walked for once a minute each, for
-- good. Given up after this many tries, until the next world.
local LEARN_GIVE_UP = 6
local classMisses = {}   -- short name -> failed tries in this world
-- A class that is not an actor (Shelve_Container_C is a StaticMeshComponent)
-- can only be listed by walking, so it is walked this rarely.
local COMPONENT_WALK_EVERY = 60
local componentWalkAt = {}

--- Climb from a class to the one called `short` - FindFirstOf matches
--- subclasses (measured: Cartridge_Base_C hands back a videotape_C) - noting
--- on the way whether it is an actor class at all.
local function describeClass(cls, short)
    local path, isActor = nil, false
    local c = cls
    for _ = 1, 48 do
        if not valid(c) then break end
        local full = nil
        pcall(function() full = c:GetFullName() end)
        local p = type(full) == "string" and full:match("^%S+%s+(.+)$") or nil
        if not p then break end
        if path == nil and p:match("([^%.]+)$") == short then path = p end
        if p == "/Script/Engine.Actor" then
            isActor = true
            break
        end
        local up = nil
        pcall(function() up = c:GetSuperStruct() end)
        c = up
    end
    return path, isActor
end

--- The class object, for this tick. A native class never unloads, so it is
--- the one kind of class kept for good; a Blueprint class can (its package
--- goes when nothing uses it) and is found again each tick.
local function classObject(info)
    if info.path:find("^/Script/") then
        local key = "class:" .. info.path
        local c = roots[key]
        if c ~= nil and valid(c) then return c end
        c = UE.findObject(info.path)
        roots[key] = c
        return c
    end
    return UE.findObject(info.path)
end

local function classFor(short)
    local info = classInfo[short]
    if info then return info end

    -- Cheap, so tried every time until the class loads: a known path, or the
    -- engine's own package for a native class name.
    local guess = KNOWN_CLASSES[short]
    local known = guess ~= nil
    if not guess and not short:find("_C$") then guess = "/Script/Engine." .. short end
    if guess then
        local c = UE.findObject(guess)
        if c then
            local path, isActor = describeClass(c, short)
            if path then
                info = { path = path, actor = isActor }
                classInfo[short] = info
                return info
            end
        end
    end

    -- Otherwise learn it from something alive: one walk, backed off for as
    -- long as nothing of that class exists. A new world starts it over.
    local t = os.clock()
    if t < (classRetryAt[short] or 0) then return nil end
    stats.walks = stats.walks + 1
    local o = FindFirstOf(short)
    if valid(o) then
        local cls = nil
        pcall(function() cls = o:GetClass() end)
        local path, isActor = describeClass(cls, short)
        info = { path = path, actor = isActor and path ~= nil }
        classInfo[short] = info
        classRetryAt[short], classBackoff[short] = nil, nil
        return info
    end
    local wait = classBackoff[short] or LEARN_FIRST_WAIT
    classMisses[short] = (classMisses[short] or 0) + 1
    -- A class whose path we know is found by that, the moment it loads (above):
    -- the walk is only a backstop for a wrong path, once. MEASURED (16 Oct
    -- 2026): retried for classes a store does not have, it was 30-70 ms of a
    -- frame each time, dozens of times in a session's first minutes.
    classRetryAt[short] = (known or classMisses[short] >= LEARN_GIVE_UP) and math.huge or (t + wait)
    classBackoff[short] = math.min(wait * 2, LEARN_MAX_WAIT)
    return nil
end

--- Let go of a table passed for an out-parameter.
---
--- UE4SS (this build) takes a Lua registry reference to every table passed
--- for an out-parameter and never releases it (call_ufunction_from_lua:
--- registry().make_ref(), no unref), so the table, and every wrapper in it,
--- lives as long as the game does. MEASURED in 1.7.0: the registry grew by
--- about 4 entries a second, one per actor list, each holding hundreds of
--- wrappers. Call this right after the call. Only the entry holding this very
--- table is removed; UE4SS never reads it again once the call has returned.
function UE.releaseOut(t)
    if type(t) ~= "table" or not (debug and debug.getregistry) then return end
    local reg = debug.getregistry()
    if type(reg) ~= "table" then return end
    -- A new reference goes at the end of the array part: look there first.
    local n = #reg
    for k = n, math.max(1, n - 16), -1 do
        if rawget(reg, k) == t then
            reg[k] = nil
            return
        end
    end
    for k, v in pairs(reg) do
        if v == t then
            reg[k] = nil
            return
        end
    end
end

--- Run fn with a fresh table for an FHitResult out-parameter (the K2_Set*
--- location and rotation calls), then release it. Errors still propagate.
function UE.withHit(fn)
    local hit = {}
    local ok, err = pcall(fn, hit)
    UE.releaseOut(hit)
    if not ok then error(err, 0) end
end

--- Has a class by this name been found (and its path learned)?
function UE.classKnown(short)
    return classInfo[short] ~= nil
end

--- Is it known to be something other than an actor (a component class, say)?
--- false while unknown.
function UE.classIsNotActor(short)
    local info = classInfo[short]
    return info ~= nil and info.actor == false
end

--- Tell the lookups where an actor class lives, when its path is already
--- known - the host named it - so findFirst / findAll never walk to learn it.
function UE.knowClass(short, path)
    if type(short) ~= "string" or type(path) ~= "string" or classInfo[short] then return end
    if not path:match("^/Game/[%w_/%-%.]+$") or path:match("([^%.]+)$") ~= short then return end
    classInfo[short] = { path = path, actor = true }
end

--- Write an FText PROPERTY. Never `obj.Prop = FText(s)` (nor UE.TrySet with
--- an FText): MEASURED on this build, UE4SS writes 0x18 bytes for an FText
--- where the engine's is 0x10 (header dump), so the 8 bytes after the
--- property are overwritten - an end-of-day statistic row's Font Size became
--- 4.98e+20 and the row vanished; a text sign's "UI Text Command" pointer,
--- right after its "User Text", turned to garbage for the garbage collector
--- to find. KismetSystemLibrary SetTextPropertyByName takes the text as its
--- LAST parameter (the extra bytes land in unused parameter space) and the
--- engine copies it at its real size. FText parameters elsewhere (SetText)
--- are fine for the same reason when they are the only or last one.
function UE.setText(obj, prop, s)
    local ksl = kismet()
    if not (ksl and valid(obj)) or type(prop) ~= "string" or type(s) ~= "string" then return false end
    return (pcall(function() ksl:SetTextPropertyByName(obj, FName(prop), FText(s)) end))
end

--- An asset or class by path, loaded now if it is not in memory yet: a mesh
--- only the host's furniture used so far, a widget only a GameMode creates.
--- KismetSystemLibrary LoadAsset_Blocking - a blocking load on the game
--- thread, so for one path once in a while, never every tick.
function UE.load(path)
    local o = UE.findObject(path)
    if o then return o end
    local ksl = kismet()
    if not ksl or type(path) ~= "string" then return nil end
    local got = nil
    pcall(function()
        got = ksl:LoadAsset_Blocking(ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(path)))
    end)
    if not valid(got) then return nil end
    frame()
    cache["O:" .. path] = got
    return got
end

--- Every live actor of a class in the current world, subclasses included, or
--- nil when there is none: FindAllOf's contract, without the walk, for any
--- actor class. Anything else (widgets, components, assets) still walks, at
--- most once per tick. Returns a new table each call.
function UE.findAll(short)
    frame()
    local key = "A:" .. short
    local hit = cache[key]
    if hit == nil then
        hit = false
        local gs, gi = engineRoute()
        local info = gs and classFor(short)
        if not gs or (info and not info.actor) then
            local t = os.clock()
            if not info or t >= (componentWalkAt[short] or 0) then
                if info then componentWalkAt[short] = t + COMPONENT_WALK_EVERY end
                stats.walks = stats.walks + 1
                hit = FindAllOf(short) or false
            end
        elseif info then
            local cls = classObject(info)
            if cls then
                local out = {}
                stats.lists = stats.lists + 1
                if UE.trace then UE.trace("GetAllActorsOfClass", short) end
                local called = pcall(function() gs:GetAllActorsOfClass(gi, cls, out) end)
                if UE.trace then UE.trace("read list of", short) end
                UE.releaseOut(out)
                if called then
                    stats.listed = stats.listed + #out
                    local list = {}
                    pcall(function()
                        local wrapped = out[1] ~= nil and out[1]:type() == "RemoteUnrealParam"
                        for i = 1, #out do
                            local o = out[i]
                            if wrapped then o = o:get() end
                            if valid(o) then list[#list + 1] = o end
                        end
                    end)
                    if #list > 0 then hit = list end
                else
                    hit = FindAllOf(short) or false
                end
            end
            -- Not loaded: nothing of the class can exist.
        end
        -- No info: nothing of the class has been seen yet.
        cache[key] = hit
    end
    if hit then return copy(hit) end
    return nil
end

--- The first live actor of a class, or nil: GetActorOfClass (0.008 ms) for
--- an actor class, a walk - once per tick at most - for anything else.
function UE.findFirst(short)
    frame()
    local key = "F:" .. short
    local hit = cache[key]
    if hit == nil then
        hit = false
        local gs, gi = engineRoute()
        local info = gs and classFor(short)
        local o = nil
        if not gs or (info and not info.actor) then
            stats.walks = stats.walks + 1
            o = FindFirstOf(short)
        elseif info then
            local cls = classObject(info)
            if UE.trace then UE.trace("GetActorOfClass", short) end
            if cls and not pcall(function() o = gs:GetActorOfClass(gi, cls) end) then
                o = FindFirstOf(short)
            end
        end
        if valid(o) then hit = o end
        cache[key] = hit
    end
    return hit or nil
end

function UE.beginFrame()
    cache = {}
    frameOpen = true
    -- A new world (travel, the store reloading): forget what was missing from
    -- the old one, so it is looked for again straight away.
    local gi = roots.gi
    if gi ~= nil and valid(gi) then
        local addr = nil
        pcall(function() addr = gi:GetWorld():GetAddress() end)
        if addr ~= worldAddr then
            worldAddr = addr
            classRetryAt, classBackoff, classMisses, componentWalkAt = {}, {}, {}, {}
        end
    end
end

--- The tick is over: nothing it found may be used after this.
function UE.endFrame()
    cache = {}
    frameOpen = false
end

--- Tests only: forget everything this section learned.
function UE._resetLookups()
    cache, roots = {}, {}
    classInfo, classRetryAt, classBackoff, classMisses, componentWalkAt = {}, {}, {}, {}, {}
    forever, softRefs, softCount = {}, {}, 0
    giRetryAt, worldAddr, lastTickPc, frameOpen = 0, nil, nil, false
end

function UE.GetEngine()
    local e = roots.engine
    if e ~= nil and valid(e) then return e end
    e = FindFirstOf("GameEngine")     -- it lives as long as the process
    if valid(e) then
        roots.engine = e
        return e
    end
    return nil
end

function UE.GetWorld()
    frame()
    if cache.world ~= nil then
        if valid(cache.world) then return cache.world end
        return nil
    end
    local w = nil
    local gi = gameInstance()
    if gi then pcall(function() w = gi:GetWorld() end) end
    if not valid(w) then
        w = nil
        local pc = UE.GetPlayerController()
        if valid(pc) then pcall(function() w = pc:GetWorld() end) end
    end
    if valid(w) then
        cache.world = w
        return w
    end
    cache.world = false
    return nil
end

--- Is this controller the one sitting at THIS machine's keyboard?
---
--- Do not shorten this to "does it have a Player?". That is true of remote
--- controllers as well, because UNetConnection derives from UPlayer - so on a
--- listen server the host's own lookups could land on a guest's controller and
--- report the guest's pawn, camera and name as the local player's. Ask the
--- engine, and fall back to the class of the Player object, which is a
--- ULocalPlayer only for the real one.
function UE.IsLocalController(pc)
    if not valid(pc) then return false end

    local ok, v = pcall(function() return pc:IsLocalController() end)
    if ok and type(v) == "boolean" then return v end

    local p = UE.TryGet(pc, "Player")
    if valid(p) then
        return UE.ClassNameOf(p):find("LocalPlayer") ~= nil
    end
    return false
end

--- Every player controller in the world, from the engine's own list - on a
--- listen server the host's and every guest's, on a guest its own - or nil
--- when that route is not available.
local function engineControllers()
    local gs, gi = engineRoute()
    if not gs then return nil end
    local list, seen = {}, {}
    if UE.trace then UE.trace("player controllers") end
    local ok = pcall(function()
        local n = gs:GetNumPlayerControllers(gi) or 0
        for i = 0, n - 1 do
            local pc = gs:GetPlayerController(gi, i)
            if valid(pc) then
                -- While RewindNative answers for a guest (native.lua), index 0
                -- comes back as that guest too. Count each controller once.
                local key = pc
                pcall(function() key = pc:GetAddress() end)
                if not seen[key] then
                    seen[key] = true
                    list[#list + 1] = pc
                end
            end
        end
    end)
    if ok then return list end
    return nil
end

local function rememberPc(pc)
    cache.pc = pc
    if frameOpen and pc then lastTickPc = pc end
    return pc or nil
end

function UE.GetPlayerController()
    frame()
    if cache.pc ~= nil then
        if valid(cache.pc) then return cache.pc end
        return nil
    end

    local list = engineControllers()
    if list then
        for _, pc in ipairs(list) do
            if UE.IsLocalController(pc) then return rememberPc(pc) end
        end
        if #list == 0 then return rememberPc(false) end
        -- Controllers, none of them local: only while the native redirect
        -- answers for a guest. The walk below still knows which is ours.
    end

    local all = FindAllOf("PlayerController")
    if all then
        -- A genuinely local controller, if the engine will tell us which.
        for _, pc in ipairs(all) do
            if valid(pc) and UE.IsLocalController(pc) then return rememberPc(pc) end
        end
        -- Then anything owned by a player at all, then anything at all. In
        -- single player - which is every path before a session starts - the
        -- first of these is the only controller in existence anyway.
        for _, pc in ipairs(all) do
            if valid(pc) and valid(pc.Player) then return rememberPc(pc) end
        end
        for _, pc in ipairs(all) do
            if valid(pc) then return rememberPc(pc) end
        end
    end
    return rememberPc(false)
end

--- The local PlayerController for the 30 Hz key poll (input.lua), which runs
--- between ticks and must never walk the object array. The engine route is
--- cheap enough to ask fresh every time; without it (the test harness), the
--- controller the last tick found.
function UE.peekPlayerController()
    local list = engineControllers()
    if list then
        for _, pc in ipairs(list) do
            if UE.IsLocalController(pc) and UE.alive(pc) then return pc end
        end
        return nil
    end
    local pc = lastTickPc
    if pc and UE.alive(pc) then return pc end
    return nil
end

function UE.GetAllPlayerControllers()
    frame()
    local list = cache.pcs
    if list == nil then
        list = engineControllers()
        if list == nil then
            list = {}
            for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
                if valid(pc) then list[#list + 1] = pc end
            end
        end
        cache.pcs = list
    end
    return copy(list)
end

function UE.GetPawn()
    frame()
    if cache.pawn ~= nil then
        if valid(cache.pawn) then return cache.pawn end
        return nil
    end
    local pc = UE.GetPlayerController()
    if valid(pc) and valid(pc.Pawn) then
        cache.pawn = pc.Pawn
        return cache.pawn
    end
    cache.pawn = false
    return nil
end

--- The walking fallback: resolve once per tick and remember, including the
--- negative result.
local function cachedLookup(key, names)
    frame()
    if cache[key] ~= nil then
        if valid(cache[key]) then return cache[key] end
        return nil
    end
    for _, n in ipairs(names) do
        local o = FindFirstOf(n)
        if valid(o) then
            cache[key] = o
            return o
        end
    end
    cache[key] = false
    return nil
end

--- A GameplayStatics getter that takes only a world context, once per tick.
local function fromStatics(key, fnName, fallbackNames)
    frame()
    if cache[key] == nil then
        local gs, gi = engineRoute()
        if not gs then return cachedLookup(key, fallbackNames) end
        local o = nil
        pcall(function() o = gs[fnName](gs, gi) end)
        cache[key] = valid(o) and o or false
    end
    if valid(cache[key]) then return cache[key] end
    return nil
end

function UE.GetGameMode()
    -- Only exists on the host / standalone.
    return fromStatics("gm", "GetGameMode", { "Core_Gamemode_C", "GameModeBase" })
end

function UE.GetGameState()
    return fromStatics("gs", "GetGameState", { "GameStateBase" })
end

function UE.GetGameInstance()
    local gi = gameInstance()
    if gi then return gi end
    return cachedLookup("gi", { "Core_GameInstance_C", "GameInstance" })
end

function UE.GetKismetSystemLibrary()
    return kismet()
end

function UE.GetGameplayStatics()
    return statics()
end

--------------------------------------------------------------------------
-- Network role helpers
--------------------------------------------------------------------------

-- ENetRole: 0 None, 1 SimulatedProxy, 2 AutonomousProxy, 3 Authority
UE.ROLE_NONE, UE.ROLE_SIMULATED, UE.ROLE_AUTONOMOUS, UE.ROLE_AUTHORITY = 0, 1, 2, 3

--- True when this process owns the simulation (listen server or standalone).
function UE.IsServer()
    local w = UE.GetWorld()
    if not valid(w) then return true end -- pre-travel: treat as standalone
    -- NetMode: 0 Standalone, 1 DedicatedServer, 2 ListenServer, 3 Client
    local nm = UE.GetNetMode()
    return nm ~= 3
end

function UE.IsClient()
    return UE.GetNetMode() == 3
end

function UE.IsHosting()
    return UE.GetNetMode() == 2
end

function UE.IsStandalone()
    return UE.GetNetMode() == 0
end

--- The world's active game net driver, or nil in single player.
function UE.GetNetDriver()
    frame()
    if cache.nd ~= nil then
        if valid(cache.nd) then return cache.nd end
        return nil
    end
    local nd = UE.GetNetDriverUncached()
    cache.nd = valid(nd) and nd or false
    return valid(nd) and nd or nil
end

function UE.GetNetDriverUncached()
    local w = UE.GetWorld()
    if not valid(w) then return nil end
    local readable, nd = pcall(function() return w.NetDriver end)
    if readable then
        -- The world answered, and no driver means single player. Do not go
        -- looking: the walk below used to run every tick of every
        -- single-player session (15 ms each).
        if valid(nd) then return nd end
        return nil
    end
    -- Some builds only expose it through the engine's world list.
    local drivers = FindAllOf("NetDriver")
    if drivers then
        for _, d in ipairs(drivers) do
            if valid(d) then
                -- An FName, so it has to be asked for its text: tostring()
                -- gives "FNameUserdata: 0000..." and never matches "Game",
                -- which quietly made this whole fallback path a no-op.
                local name = UE.ToStr(UE.TryGet(d, "NetDriverName"))
                if name and name:find("Game") then return d end
            end
        end
    end
    return nil
end

--- Read the world's net mode.
---
--- There is no UKismetSystemLibrary::GetNetMode - GetNetMode lives on AActor
--- and UWorld as plain C++, so it is not reachable through reflection. We
--- reproduce UWorld::InternalGetNetMode instead, which is simply: no net
--- driver means standalone, a net driver with a ServerConnection means we are
--- a client, and a net driver without one means we are the server.
function UE.GetNetMode()
    local nd = UE.GetNetDriver()
    if not valid(nd) then return 0 end                    -- Standalone
    local sc = UE.TryGet(nd, "ServerConnection")
    if valid(sc) then return 3 end                        -- Client
    return 2                                              -- ListenServer
end

--- Human-readable net driver summary for diagnostics.
function UE.DescribeNetDriver()
    local nd = UE.GetNetDriver()
    if not valid(nd) then return "none (single player)" end
    local cls  = UE.ClassNameOf(nd)
    -- NetDriverName is an FName, which stringifies to "FNameUserdata: 0000..."
    -- unless it is asked for its text.
    local name = UE.ToStr(UE.TryGet(nd, "NetDriverName")) or "?"
    local sc   = UE.TryGet(nd, "ServerConnection")
    local conns = UE.TryGet(nd, "ClientConnections")
    local n = 0
    if conns ~= nil then pcall(function() n = conns:GetArrayNum() end) end
    return ("%s (name=%s, serverConn=%s, clients=%d)")
        :format(cls, name, valid(sc) and "yes" or "no", n)
end

function UE.NetModeName()
    local n = UE.GetNetMode()
    return ({ [0] = "Standalone", [1] = "DedicatedServer", [2] = "ListenServer", [3] = "Client" })[n] or "Unknown"
end

--------------------------------------------------------------------------
-- Console commands
--------------------------------------------------------------------------

--- Run a console command locally. Returns true if it was dispatched.
function UE.Exec(command)
    local pc = UE.GetPlayerController()
    if valid(pc) then
        local ok = pcall(function() pc:ConsoleCommand(command, false) end)
        if ok then
            Log.debug("exec (pc): %s", command)
            return true
        end
    end
    local ksl, w = UE.GetKismetSystemLibrary(), UE.GetWorld()
    if valid(ksl) and valid(w) then
        local ok = pcall(function() ksl:ExecuteConsoleCommand(w, command, pc) end)
        if ok then
            Log.debug("exec (ksl): %s", command)
            return true
        end
    end
    Log.error("could not execute console command: %s", command)
    return false
end

--------------------------------------------------------------------------
-- Runtime component construction
--------------------------------------------------------------------------

--- Build a component and hand it back unregistered, or nil.
---
--- THIS IS THE ARGUMENT LIST THAT PROBABLY CRASHED THE GAME, and the reason
--- Config.SafeMode has been on by default since 1.1.2. UE4SS's
--- StaticConstructObject mirrors FStaticConstructObjectParameters:
---
---   (Class, Outer, Name, SetFlags, InternalSetFlags,
---    bCopyTransientsFromClassDefaults, bAssumeTemplateIsArchetype,
---    InTemplate, InInstanceGraph, ExternalPackage, SubobjectOverrides)
---
--- Both callers passed `(cls, outer, name, 0, 0, nil, false, false, nil)`.
--- Line those up: position 6 is a bool and got nil, and position 8 is a
--- UObject* and got `false`. Handing a boolean to a pointer parameter is
--- exactly the shape of fault that goes bang inside
--- StaticConstructObject_Internal - and "creating a TextRenderComponent on a
--- live pawn crashes this build" was the conclusion drawn from it, which
--- blamed the feature rather than the call.
---
--- Every parameter after Name is optional, so the three-argument form is both
--- correct and the smallest possible surface to get wrong. The explicit form
--- is kept as a fallback, with the right types this time, in case a UE4SS
--- build insists on them.
function UE.NewComponent(cls, outer, name)
    if not (valid(cls) and valid(outer)) then return nil end

    local comp = nil
    local ok, err = pcall(function()
        comp = StaticConstructObject(cls, outer, name)
    end)
    if valid(comp) then return comp end
    Log.debug("StaticConstructObject/3 gave nothing (%s)", tostring(err))

    ok, err = pcall(function()
        comp = StaticConstructObject(cls, outer, name, 0, 0, false, false, nil)
    end)
    if valid(comp) then return comp end
    Log.debug("StaticConstructObject/8 gave nothing (%s)", tostring(err))

    return nil
end

--------------------------------------------------------------------------
-- Reflection helpers
--------------------------------------------------------------------------

--- Describe a UFunction's parameters. Used to adapt to plugin API differences
--- instead of hard-coding a signature we cannot verify.
--- Returns a list of { name = string, class = string } or nil.
function UE.DescribeFunction(fn)
    if not valid(fn) then return nil end
    local params = {}
    local ok = pcall(function()
        fn:ForEachProperty(function(prop)
            params[#params + 1] = {
                name  = prop:GetFName():ToString(),
                class = prop:GetClass():GetFName():ToString(),
            }
        end)
    end)
    if not ok then return nil end
    return params
end

function UE.DescribeFunctionString(fn)
    local params = UE.DescribeFunction(fn)
    if not params then return "<unknown signature>" end
    local parts = {}
    for _, p in ipairs(params) do
        parts[#parts + 1] = ("%s %s"):format(p.class, p.name)
    end
    return "(" .. table.concat(parts, ", ") .. ")"
end

--- Find the first object of any of the given class names.
function UE.FindFirstOfAny(names)
    for _, n in ipairs(names) do
        local o = UE.findFirst(n)
        if valid(o) then return o, n end
    end
    return nil, nil
end

--- Read a field off an engine struct regardless of its letter case.
---
--- MEASURED in 1.7.0: an FRotator returned by PlayerCameraManager comes back
--- as { pitch = .., Yaw = .., Roll = .. } - lowercase "pitch". FNames are
--- case-insensitive and print with whatever casing was registered FIRST in
--- the process, and UE4SS builds struct tables from FNames, so "rot.Pitch"
--- can be nil on one build and fine on the next. Every read of an engine
--- struct's field should go through here.
function UE.field(t, name)
    if t == nil then return nil end
    local v = nil
    pcall(function() v = t[name] end)
    if v ~= nil then return v end
    pcall(function() v = t[name:lower()] end)
    if v ~= nil then return v end
    pcall(function() v = t[name:upper()] end)
    return v
end

--- An engine FRotator as a plain { Pitch, Yaw, Roll } table, or nil.
function UE.rot(t)
    if t == nil then return nil end
    local p, y, r = UE.field(t, "Pitch"), UE.field(t, "Yaw"), UE.field(t, "Roll")
    if type(p) ~= "number" and type(y) ~= "number" then return nil end
    return { Pitch = p or 0.0, Yaw = y or 0.0, Roll = r or 0.0 }
end

--- A rotator to HAND to the engine (a parameter, a property write).
---
--- The read side's casing problem (UE.field, above) has a write side, and it
--- is worse because it is silent. UE4SS fills an FRotator parameter by
--- looking each field up under the name table's casing, which on this build
--- is "pitch", "Yaw", "Roll". MEASURED: SetControlRotation({ Pitch = -30, .. })
--- set a pitch of 0, the same call with `pitch = -30` set -30, and
--- Conv_RotatorToVector({ Pitch = 45 }) came back level. So every rotator
--- this mod built as { Pitch = .. } reached the engine with no pitch: guest
--- actions were replayed looking dead level (a guest could pick up what was
--- at eye height and nothing on the floor), and the sun copied to a guest
--- sat on the horizon. FLinearColor (R, G, B, A) and FVector are unaffected.
--- Both casings, so it works whichever way the name table goes.
function UE.rotArg(t)
    local r = UE.rot(t)
    if not r then return nil end
    return { Pitch = r.Pitch, pitch = r.Pitch, Yaw = r.Yaw, yaw = r.Yaw,
             Roll = r.Roll, roll = r.Roll }
end

--- An engine FVector as a plain { X, Y, Z } table, or nil.
function UE.vec(t)
    if t == nil then return nil end
    local x, y, z = UE.field(t, "X"), UE.field(t, "Y"), UE.field(t, "Z")
    if type(x) ~= "number" then return nil end
    return { X = x, Y = y or 0.0, Z = z or 0.0 }
end

--- Keep a member name alive for as long as this Lua state lives, and return it.
---
--- MEASURED in a guest's crash dump (RewindNative.cpp, "THE UE4SS NAME
--- CACHE"): UE4SS remembers every name used on an engine object - obj.Mesh,
--- obj:Possess(), obj[name] - by a pointer into the Lua string it came in as,
--- and never copies it. A name written in the source lives as long as the
--- module does. A name BUILT at run time (concatenated, formatted, read off
--- the engine like inspect.lua's property names, or typed into the dev
--- bridge) is collected once nothing holds it, and UE4SS is left holding a
--- pointer to freed memory - which it reads the next time it learns a new
--- name and has to grow. So any name that is not a literal goes through here
--- (or through TryGet/TrySet/TryCall, which do it) before it touches an
--- object. A hot reload frees every string at once; that case is native.lua's.
local pinned = {}
function UE.pin(name)
    if type(name) == "string" then pinned[name] = true end
    return name
end

--- Tests only: is this name pinned?
function UE._isPinned(name) return pinned[name] == true end

--- Get a property if it exists, without throwing when it does not.
function UE.TryGet(obj, propertyName)
    if not valid(obj) then return nil end
    if type(propertyName) == "string" then pinned[propertyName] = true end
    local ok, v = pcall(function() return obj[propertyName] end)
    if ok then return v end
    return nil
end

function UE.TrySet(obj, propertyName, value)
    if not valid(obj) then return false end
    if type(propertyName) == "string" then pinned[propertyName] = true end
    return (pcall(function() obj[propertyName] = value end))
end

--- Call a UFunction by name if the object has it.
function UE.TryCall(obj, fnName, ...)
    if not valid(obj) then return false, nil end
    if type(fnName) == "string" then pinned[fnName] = true end
    local args = { ... }
    local ok, ret = pcall(function() return obj[fnName](obj, table.unpack(args)) end)
    return ok, ret
end

--- Pull a SteamID64 out of whatever SteamCore hands back.
---
--- SteamCore wraps IDs in an FSteamID struct rather than returning a plain
--- integer, and the field name is not published with the shipped game. Rather
--- than guessing once and failing silently, try every plausible field, then
--- fall back to scraping a 17-digit id out of the value's string form.
--- Returns the id as a string, plus a short note describing how it was found.
local ID_FIELDS = {
    "Value", "SteamID", "SteamId", "ID", "Id", "Identifier",
    "SteamID64", "UniqueNetId", "m_steamid", "Data", "Raw",
}

--- Render a numeric SteamID exactly.
---
--- A SteamID64 is around 7.6e16, which is past 2^53 - the largest integer a
--- double can hold exactly. Formatting one with "%.0f" silently rounds it,
--- producing an id that is a few digits wrong and a join that always fails.
--- Lua 5.4 has real 64-bit integers, so tostring() on an integer is exact;
--- anything that arrives as a float has already lost precision and is
--- reported as such rather than passed off as correct.
local function numberToId(v)
    if math.type(v) == "integer" then
        return tostring(v), true
    end
    -- Float: best effort, but flag it as untrustworthy.
    local ok, s = pcall(string.format, "%.0f", v)
    if not ok then return nil, false end
    return s, false
end

local function looksLikeId(s)
    return type(s) == "string" and #s >= 15 and s:match("^%d+$") ~= nil
end

function UE.ExtractSteamId(value)
    if value == nil then return nil, "nil" end

    -- Already a plain value.
    if type(value) == "number" then
        local s, exact = numberToId(value)
        if looksLikeId(s) then
            return s, exact and "number" or "number (IMPRECISE - was a float)"
        end
    end
    if type(value) == "string" then
        local m = value:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)")
        if m then return m, "string" end
    end

    -- A struct: probe the usual field names. Strings are preferred over
    -- numbers because they cannot have been rounded on the way here.
    for _, f in ipairs(ID_FIELDS) do
        local ok, v = pcall(function() return value[f] end)
        if ok and v ~= nil then
            if type(v) == "string" then
                local m = v:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)")
                if m then return m, "field " .. f end
            elseif type(v) == "number" then
                local s, exact = numberToId(v)
                if looksLikeId(s) then
                    return s, exact and ("field " .. f)
                        or ("field " .. f .. " (IMPRECISE - was a float)")
                end
            else
                -- Nested one level (e.g. FSteamID{ UniqueNetId{ Value } }).
                for _, g in ipairs(ID_FIELDS) do
                    local ok2, v2 = pcall(function() return v[g] end)
                    if ok2 then
                        if type(v2) == "string" then
                            local m = v2:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)")
                            if m then return m, ("field %s.%s"):format(f, g) end
                        elseif type(v2) == "number" then
                            local s, exact = numberToId(v2)
                            if looksLikeId(s) then
                                return s, ("field %s.%s%s"):format(f, g,
                                    exact and "" or " (IMPRECISE - was a float)")
                            end
                        end
                    end
                end
            end
        end
    end

    -- Last resort: some builds stringify structs with their contents.
    local ok, s = pcall(tostring, value)
    if ok and type(s) == "string" then
        local m = s:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)")
        if m then return m, "tostring" end
    end

    return nil, "unrecognised (" .. type(value) .. ")"
end

function UE.ClassNameOf(obj)
    if not valid(obj) then return "<invalid>" end
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    if ok then return name end
    return "<unknown>"
end

--- Strip the cooked Blueprint "_C" suffix for friendlier matching.
function UE.BaseClassName(name)
    return (name:gsub("_C$", ""))
end

return UE
