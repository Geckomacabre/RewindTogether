-- Load the mod for real against the fake engine, then drive the paths that
-- have actually broken: boot, hosting with a guest who needs a pawn, and the
-- one that crashed - a guest who is leaving.

local SCRIPTS = ...
package.path = SCRIPTS .. "/?.lua;" .. package.path

local H = require("harness")
local print = H.realprint      -- the mod captures the global one

local failures = {}
local function check(name, ok, detail)
    if ok then
        print(("  PASS  %s"):format(name))
    else
        failures[#failures + 1] = name
        print(("  FAIL  %s   %s"):format(name, tostring(detail or "")))
    end
end

local function logHas(pattern)
    for _, line in ipairs(H.log) do
        if line:find(pattern, 1, true) then return true, line end
    end
    return false
end

-- ------------------------------------------------------------ 1. loading --

print("\n-- loading every module --")
for _, m in ipairs({ "log", "safety", "ue", "steamp2p", "net", "steamjoin",
                     "replication", "players", "spawn", "overlay", "chat",
                     "sync", "inspect", "bodies", "localgm", "mainmenu", "commands" }) do
    local ok, err = pcall(require, m)
    check("require " .. m, ok, err)
end

-- ------------------------------------------------- 2. config sanity check --

print("\n-- config validation --")
local Safety = require("safety")

local bad = {
    ConfigVersion = 8,
    MaxPlayers = 99, StateSyncHz = 0, P2PChannel = 900,
    PropNetUpdateFrequency = 10, PawnNetUpdateFrequency = 30,
    JoinOnLoadDelay = 3, AutoJoinDelay = 12, NametagMaxDistance = 3000,
    Port = "27015", Transport = "steam",
    PeerSteamIds = "76561198000000102",          -- string, not a list
    JoinTarget = "  76561198000000101  ",        -- padded, and a Steam ID
    JoinOnLoad = true,
    Keys = { HostGame = "F7", QuickJoin = "NOPE" },
    -- An old config.lua's SyncedState: no longer read, must not be an error.
    SyncedState = { { object = "nonsense", property = "Money", label = "Money" } },
    LogLevel = "verbose",
}
local problems = Safety.checkConfig(bad)

check("repairs MaxPlayers",        bad.MaxPlayers == 16, bad.MaxPlayers)
check("repairs StateSyncHz",       bad.StateSyncHz == 1, bad.StateSyncHz)
check("repairs P2PChannel",        bad.P2PChannel == 255, bad.P2PChannel)
check("repairs Port",              bad.Port == 27015, bad.Port)
check("forces Transport to ip",    bad.Transport == "ip", bad.Transport)
check("wraps PeerSteamIds",        type(bad.PeerSteamIds) == "table"
                                   and bad.PeerSteamIds[1] == "76561198000000102",
                                   tostring(bad.PeerSteamIds))
check("trims JoinTarget",          bad.JoinTarget == "76561198000000101", bad.JoinTarget)
check("repairs LogLevel",          bad.LogLevel == "info", bad.LogLevel)
check("flags the bad keybind",     (function()
    for _, p in ipairs(problems) do if p:find("NOPE") then return true end end
end)(), "no mention of NOPE")
check("ignores an old SyncedState", (function()
    for _, p in ipairs(problems) do if p:find("nonsense") then return false end end
    return true
end)(), "complained about a setting that is no longer read")
check("reports several problems",  #problems >= 7, #problems)

-- --------------------------------------------------------- 3. wire format --

print("\n-- P2P wire format --")
local P2P = require("steamp2p")
local wire = P2P.encode("state", { v1 = "42|00", v2 = "a=b", t = "1" })
local mt, fields = P2P.decode(wire)
check("round-trips the type",   mt == "state", mt)
check("escapes a pipe",         fields.v1 == "42|00", fields.v1)
check("escapes an equals",      fields.v2 == "a=b", fields.v2)
check("rejects foreign data",   P2P.decode("hello world") == nil)

-- Discovery, with the Steam plugin present. This is the path that was broken
-- on both machines and that the harness could not reach until it grew stubs:
-- a throw anywhere in the reporting used to leave api.ready false forever.
local discovered = P2P.discover()
check("discovery completes",      discovered == true, tostring(discovered))
check("and reports itself ready", P2P.isReady(), "api.ready was never set")
check("no error escaped discovery", not logHas("attempt to index a nil value"),
      "the discovery report threw")
check("read the declared ID type", logHas("declared as StructProperty"),
      "never reported the parameter class")

-- -------------------------------------------------------- 4. boot the mod --

print("\n-- booting main.lua (standalone, nothing in the world) --")
local ok, err = pcall(require, "main")
check("main.lua loads and starts", ok, err)
check("a tick loop was installed", #H.ticks == 1, #H.ticks)
check("keys are polled on the game thread, not UE4SS's keybind thread",
      #H.polls == 1 and #H.keybinds == 0,
      ("%d poll loop(s), %d RegisterKeyBind callback(s)"):format(#H.polls, #H.keybinds))
check("console commands registered", H.commands["rt.help"] ~= nil)

local ticked, terr = pcall(H.tick)
check("first tick survives an empty world", ticked, terr)
for _ = 1, 5 do pcall(H.tick) end
check("five more ticks survive", true)

-- ------------------------------------------ 5. a session with a real guest --

print("\n-- listen server, guest with no pawn --")
local UE    = require("ue")
local Spawn = require("spawn")

local netConn  = H.obj("NetConnection", { __isActor = false })
local localPl  = H.obj("LocalPlayer",   { __isActor = false })

local hostPawn = H.spawn("Player_Character_C", {
    K2_GetActorLocation = function() return { X = 2037, Y = -614, Z = 136 } end,
    K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
    K2_TeleportTo       = function() return true end,
})

local hostPC = H.spawn("PlayerController", {
    Player = localPl, Pawn = hostPawn,
    IsLocalController = function() return true end,
    SetViewTargetWithBlend = function() end,
    Possess = function() end,
    GetWorld = function() return H.theWorld end,
})

local guestPC = H.spawn("PlayerController", {
    Player = netConn, Pawn = nil,
    IsLocalController = function() return false end,
    SetViewTargetWithBlend = function() end,
    Possess = function() end,
    GetWorld = function() return H.theWorld end,
})

H.theWorld = H.obj("World", { __isActor = false, NetDriver = nil })
H.theWorld.NetDriver = H.obj("IpNetDriver", {
    __isActor = false, ServerConnection = nil,
    NetDriverName = { ToString = function() return "GameNetDriver" end },
    ClientConnections = { GetArrayNum = function() return 1 end },
})

H.spawn("Core_Gamemode_C", {
    HandleStartingNewPlayer = function() end,
    SpawnDefaultPawnFor     = function() return nil end,
    K2_FindPlayerStart      = function() return nil end,
})

-- The per-frame cache remembers "looked, found nothing" from the empty-world
-- ticks above; a new frame is exactly what clears it.
UE.beginFrame()

check("net mode reads as ListenServer", UE.GetNetMode() == 2, UE.GetNetMode())
check("host controller is the local one",
      UE.GetPlayerController() == hostPC, "picked the wrong controller")
check("net driver name is text, not an address",
      UE.DescribeNetDriver():find("GameNetDriver") ~= nil, UE.DescribeNetDriver())

-- The guest is live, so the ladder is allowed to work on them. Clock is
-- driven by hand so GRACE and RETRY_INTERVAL are genuinely crossed.
local clock = 1000
local function pump(n)
    for _ = 1, (n or 1) do
        clock = clock + 1.5
        UE.beginFrame()
        Spawn.tickHost(clock)
    end
end

pump(1)
check("notices a live guest with no pawn", logHas("has no pawn"), "never noticed")

pump(6)
check("ladder fires for a live guest", logHas("attempt 1/5"), "never escalated")
check("logs that the route returned", logHas("route 1 returned"),
      "no line after the route - a native crash would be unreadable")

-- ---------------------------------------- 6. THE CRASH CASE: leaving guest --

print("\n-- the crash case: the same guest, now disconnecting --")

-- Exactly the state the real log was in: UNetConnection::CleanUp has run and
-- Destroy() has been called, but FindAllOf still returns the controller.
guestPC.Player       = nil
guestPC.__destroying = true

local mark = #H.log
pump(8)

local firedLadder = false
for i = mark + 1, #H.log do
    if H.log[i]:find("attempt %d/5") then firedLadder = true end
end
check("ladder does NOT fire at a leaving guest", not firedLadder,
      "it tried to give a pawn to a controller being destroyed")
check("says they left instead", logHas("left before they could be given"),
      "no explanation logged")

-- --------------------- 6a. placing guests: arrivals only, and only on floor --
-- A UE4SS hot reload forgets spawn.lua's state, and 1.7.0's host then put a
-- guest who was at the till (collision off, movement off) beside itself: the
-- guest fell out of the world, out of network range and back, and crashed.
print("\n-- placing guests: arrivals only, never a pawn that cannot stand --")
do
    local conn = H.obj("NetConnection", { __isActor = false })
    local teleports = 0
    local function guestPawn(age, fields)
        local p = H.spawn("Player_Character_C", fields or {})
        p.GetGameTimeSinceCreation = function() return age end
        p.K2_GetActorLocation = function() return { X = 2100, Y = -600, Z = 136 } end
        p.K2_TeleportTo = function() teleports = teleports + 1 return true end
        return p
    end
    local pc2 = H.spawn("PlayerController", {
        Player = conn, Pawn = nil,
        IsLocalController = function() return false end,
        SetViewTargetWithBlend = function() end,
        Possess = function() end,
        GetWorld = function() return H.theWorld end,
    })
    local function since(m, pattern)
        for i = m + 1, #H.log do if H.log[i]:find(pattern, 1, true) then return true end end
        return false
    end

    -- After a reload: their pawn has been in the store for ten minutes.
    pc2.Pawn = guestPawn(600)
    Spawn.onSessionStart()                 -- forgets everything, as a reload does
    local m = #H.log
    pump(4)
    check("a guest who already has a pawn in the store is not moved after a reload",
          teleports == 0 and since(m, "already has a character in the store"),
          ("%d teleport(s)"):format(teleports))

    -- A real arrival: a pawn made a second ago.
    pc2.Pawn.__dead = true
    pc2.Pawn = guestPawn(1)
    Spawn.onSessionStart()
    pump(4)
    check("a new arrival is still put beside the host", teleports == 1, ("%d teleport(s)"):format(teleports))

    -- At the till: collision off.
    pc2.Pawn.__dead = true
    pc2.Pawn = guestPawn(1, { GetActorEnableCollision = function() return false end })
    Spawn.onSessionStart()
    m = #H.log
    pump(4)
    check("a pawn with its collision off is never teleported", teleports == 1 and since(m, "collision is off"),
          ("%d teleport(s)"):format(teleports))
    check("nor by rt.bring", Spawn.bringEveryone() == 0 and teleports == 1, ("%d teleport(s)"):format(teleports))

    -- Movement switched off (MOVE_None).
    pc2.Pawn.__dead = true
    pc2.Pawn = guestPawn(1, { CharacterMovement = H.obj("CharacterMovementComponent",
                                                         { __isActor = false, MovementMode = 0 }) })
    Spawn.onSessionStart()
    m = #H.log
    pump(4)
    check("nor one whose movement is switched off", teleports == 1 and since(m, "movement is switched off"),
          ("%d teleport(s)"):format(teleports))

    pc2.Pawn.__dead = true
    pc2.__dead, pc2.Player = true, nil
    H.world.objects["Player_Character_C"] = { hostPawn }
    Spawn.onSessionStart()
    UE.beginFrame()
end

-- ------------------------------------------- 6b. borrowed NPC bodies --

print("\n-- borrowing a body from an NPC --")
local Bodies = require("bodies")
local Config = require("config")

-- A donor's mesh component has a transform because it has always had a mesh
-- in it. An empty one does not: a component that has never held a mesh has
-- never had its transform set either, which is the whole reason bodies.lua has
-- to place it. Reproducing that difference is what makes the checks below
-- mean anything.
local function meshComponent(asset)
    local c
    c = H.obj("SkeletalMeshComponent", {
        __isActor              = false,
        SkeletalMeshAsset      = asset,
        AnimClass              = asset and H.obj("AnimBP_Staff_C", { __isActor = false }) or nil,
        RelativeLocation       = asset and { X = 0, Y = 0, Z = -88 }
                                       or  { X = 0, Y = 0, Z = 0 },
        RelativeRotation       = asset and { Pitch = 0, Yaw = -90, Roll = 0 }
                                       or  { Pitch = 0, Yaw = 0, Roll = 0 },
        SetSkeletalMeshAsset   = function(self, a) self.SkeletalMeshAsset = a end,
        SetAnimationMode       = function() end,
        SetComponentTickEnabled= function() end,
        SetAnimInstanceClass   = function(self, cls) self.AnimClass = cls end,
        GetAnimInstance        = function(self)
            if not self.AnimClass then return nil end
            return H.obj("AnimBP_Staff_C", { __isActor = false })
        end,

        -- UE4SS refuses to marshal the FHitResult out-parameter on some
        -- builds, and every one of these shapes is a guess about which build
        -- is running. Refuse them all: that is the worst case, it is the case
        -- the property fallback exists for, and a stub that accepts anything
        -- cannot tell a call that worked from a call that did nothing - which
        -- is precisely the bug being guarded against.
        K2_SetRelativeLocation = function() error("cannot marshal FHitResult") end,
        K2_SetRelativeRotation = function() error("cannot marshal FHitResult") end,
        SetRelativeScale3D     = function(self, s) self.RelativeScale3D = s end,

        K2_GetComponentLocation = function(self)
            return { X = 0, Y = 0, Z = (self.RelativeLocation or {}).Z or 0 }
        end,

        SetOwnerNoSee          = function() end,
        SetVisibility          = function() end,
        SetHiddenInGame        = function() end,
    })
    return c
end

-- A skeleton shared by the donor's mesh and the animations that fit it. That
-- match is the only thing making a borrowed sequence safe to play.
local sharedSkeleton = H.obj("Skeleton_Human", { __isActor = false })
H.spawn("AnimSequence", { __isActor = false, Skeleton = sharedSkeleton })
H.spawn("AnimSequence", { __isActor = false, Skeleton = sharedSkeleton })

-- An NPC to copy from (one of the store's real NPC classes), and another
-- player with an empty mesh.
H.spawn("AI_BackAlleyVendor_Character_C", { Mesh = meshComponent(
    H.obj("SkeletalMesh_Staff", { __isActor = false, Skeleton = sharedSkeleton })) })
local otherPlayerMesh = meshComponent(nil)

-- ACharacter caches the mesh offset at construction for network smoothing to
-- interpolate towards. Player_Character_C has never had a body in it, so that
-- cache is zero - and smoothing writes it back over the component every frame.
-- That is the real fault, so the fake has to have it.
local otherPlayer = H.spawn("Player_Character_C", {
    Mesh                  = otherPlayerMesh,
    BaseTranslationOffset = { X = 0, Y = 0, Z = 0 },
    BaseRotationOffset    = { X = 0, Y = 0, Z = 0, W = 1 },
    CharacterMovement     = H.obj("CharacterMovementComponent", {
        __isActor = false, NetworkSmoothingMode = 1,
    }),
})

-- One frame of UCharacterMovementComponent::SmoothClientPosition_UpdateVisuals.
local function smoothOneFrame()
    if (otherPlayer.CharacterMovement or {}).NetworkSmoothingMode == 0 then return end
    local b = otherPlayer.BaseTranslationOffset or { X = 0, Y = 0, Z = 0 }
    otherPlayerMesh.RelativeLocation = { X = b.X, Y = b.Y, Z = b.Z }
end

-- The host's own pawn gets one too, so we can prove it is left alone.
hostPawn.Mesh = meshComponent(nil)

Bodies.init(Config)
UE.beginFrame()
Bodies.tick(clock + 100)

check("dresses the other player",
      UE.valid(otherPlayerMesh.SkeletalMeshAsset), "no mesh was applied")
check("leaves your own pawn alone",
      hostPawn.Mesh.SkeletalMeshAsset == nil, "it put a body on the local player")
check("says where the body came from", logHas("borrowed from AI_BackAlleyVendor_Character_C"), "not logged")

-- 1.5.6 through 1.5.8: the body kept floating at head height. Every version
-- "fixed" it and then logged the offset it had INTENDED to apply, so the log
-- said the feet were on the floor while the player watched a man hover over
-- the counter. The engine convention is Z = -halfheight, yaw -90; nothing here
-- accepts the call shape that used to be sent unconditionally, so reaching
-- those numbers proves the fallback ran rather than that the stub was polite.
check("puts the feet on the floor even when the setter is refused",
      (otherPlayerMesh.RelativeLocation or {}).Z == -88,
      "mesh is at Z=" .. tostring((otherPlayerMesh.RelativeLocation or {}).Z))
check("faces the body the right way",
      (otherPlayerMesh.RelativeRotation or {}).Yaw == -90,
      "yaw is " .. tostring((otherPlayerMesh.RelativeRotation or {}).Yaw))
check("does not claim a placement that did not happen",
      not logHas("COULD NOT MOVE THE MESH"), "the fallback never landed it")
check("starts the animation rather than leaving a T-pose",
      logHas("animation: running"), "the body was left in its bind pose")

-- The bug rt.bodies caught on a live two-machine run: dress() applied Z-90 and
-- read Z-90 straight back off the component, and nine seconds later the same
-- component was at Z+0. The cause is network smoothing rewriting the component
-- from ACharacter's cached offset every frame.
--
-- So the test that matters is not "can the component be written" - it always
-- could - it is "does the component survive a smoothing frame". Setting the
-- component without setting the cache passes every check above and still
-- floats in game, which is exactly how this survived three versions.
check("fixes the cause, not the symptom",
      (otherPlayer.BaseTranslationOffset or {}).Z == -88,
      "BaseTranslationOffset is still Z=" ..
      tostring((otherPlayer.BaseTranslationOffset or {}).Z))
check("says so, naming the old value",
      logHas("BaseTranslationOffset set to Z-88 (was Z+0)"), "not logged")

smoothOneFrame()
check("the body is still on the floor after a smoothing frame",
      (otherPlayerMesh.RelativeLocation or {}).Z == -88,
      "smoothing put it back to Z=" .. tostring((otherPlayerMesh.RelativeLocation or {}).Z))

-- And the net underneath, for a reset this does not cover.
otherPlayer.BaseTranslationOffset = { X = 0, Y = 0, Z = 0 }
smoothOneFrame()
UE.beginFrame()
Bodies.tick(clock + 300)
smoothOneFrame()
check("recovers if the cache itself is cleared",
      (otherPlayerMesh.RelativeLocation or {}).Z == -88,
      "mesh stayed at Z=" .. tostring((otherPlayerMesh.RelativeLocation or {}).Z))

-- The borrowed body was reported "moving in a circle". The donor's animation
-- blueprint is written for a wandering pedestrian and guesses on a player
-- character; with sequences that fit the skeleton, the mod plays them off
-- measured speed instead and the blueprint stops deciding.
-- Off unless asked for. This search enumerates loaded AnimSequences, and the
-- uncapped version of it took the host's process down the instant a guest
-- joined in 1.6.0. A missing config value must never switch it back on - which
-- is the opposite of every other flag in bodies.lua, and the reason it is
-- checked with == true rather than ~= false.
check("the animation search is off by default",
      Config.DriveBodyAnimation ~= true,
      "a sweep that has already crashed the game is enabled by default")

local played = {}
otherPlayerMesh.PlayAnimation = function(_, seq) played[#played + 1] = seq end
otherPlayer.GetVelocity = function() return { X = 150, Y = 0, Z = 0 } end
Config.DriveBodyAnimation = true

-- A re-dress needs an empty mesh, the same as the first one did: dress()
-- deliberately leaves a body that already has a mesh alone.
otherPlayerMesh.SkeletalMeshAsset = nil
Bodies.retry()
UE.beginFrame(); Bodies.tick(clock + 320)     -- dresses, finds the sequences
UE.beginFrame(); Bodies.tick(clock + 321)     -- fast path: walking
check("plays a walk cycle when the player is walking", #played == 1,
      ("PlayAnimation called %d time(s)"):format(#played))
check("says it took the pose off the donor's blueprint",
      logHas("driving the animation directly"), "not logged")

otherPlayer.GetVelocity = function() return { X = 0, Y = 0, Z = 0 } end
UE.beginFrame(); Bodies.tick(clock + 322)
UE.beginFrame(); Bodies.tick(clock + 323)
check("switches to idle once, not once per tick", #played == 2,
      ("PlayAnimation called %d time(s) total"):format(#played))
Config.DriveBodyAnimation = false

-- With nobody else present it must name the OTHER bug rather than sit quiet.
H.world.objects["Player_Character_C"] = { hostPawn }
Bodies.retry()
local m2 = #H.log
UE.beginFrame()
Bodies.tick(clock + 200)
local said = false
for i = m2 + 1, #H.log do
    if H.log[i]:find("replication problem", 1, true) then said = true end
end
check("calls out a missing pawn as a replication problem", said, "stayed silent")

-- ------------------------- 6b'. pawns the engine destroys and makes again --
-- On a guest the host's pawn - and every NPC - is destroyed when the guest
-- leaves network range, and comes back as a NEW actor under a new name
-- (measured in 1.7.0, a guest falling out of the store and back). Nothing of
-- one poll may be kept for the next.
print("\n-- bodies: a pawn destroyed for relevancy and made again --")
do
    local walks = {}
    local realFindAllOf = FindAllOf
    _G.FindAllOf = function(name) walks[#walks + 1] = name return realFindAllOf(name) end
    local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

    local function remotePawn()
        local mesh = meshComponent(nil)
        mesh.PlayAnimation = function() end
        local p = H.spawn("Player_Character_C", {
            Mesh = mesh,
            BaseTranslationOffset = { X = 0, Y = 0, Z = 0 },
            BaseRotationOffset    = { X = 0, Y = 0, Z = 0, W = 1 },
            CharacterMovement     = H.obj("CharacterMovementComponent", {
                __isActor = false, NetworkSmoothingMode = 1 }),
            GetVelocity = function() return { X = 150, Y = 0, Z = 0 } end,
        })
        return p, mesh
    end

    H.world.objects["Player_Character_C"] = { hostPawn }
    local first, firstMesh = remotePawn()
    local firstKey = first:GetFullName()
    Config.DriveBodyAnimation = true
    Bodies.retry()
    local t = clock + 1000
    UE.beginFrame(); Bodies.tick(t)
    local books = Bodies._books()
    check("the host's pawn is dressed", UE.valid(firstMesh.SkeletalMeshAsset) and books.dressed[firstKey] ~= nil,
          "not dressed")
    local seqs = books.anim[firstKey] and books.anim[firstKey].seqs
    check("its animations are kept by path, never as objects",
          seqs ~= nil and type(seqs.walk) == "string" and type(seqs.idle) == "string",
          seqs and type(seqs.walk) or "no sequences")

    -- Out of range: the engine destroys it.
    first.__dead = true
    H.world.objects["Player_Character_C"] = { hostPawn }
    UE.beginFrame(); Bodies.tick(t + 3)
    books = Bodies._books()
    check("a pawn that is gone is forgotten, every book",
          books.dressed[firstKey] == nil and books.placed[firstKey] == nil and books.anim[firstKey] == nil,
          "bookkeeping kept for a destroyed pawn")

    -- Back in range: the same player, a new actor, a new name.
    local second, secondMesh = remotePawn()
    UE.beginFrame(); Bodies.tick(t + 6)
    books = Bodies._books()
    check("the player's new pawn is dressed again", UE.valid(secondMesh.SkeletalMeshAsset)
          and books.dressed[second:GetFullName()] ~= nil, "the re-created pawn was left bare")
    check("and only it is in the books", count(books.dressed) == 1 and count(books.placed) == 1,
          ("%d dressed, %d placed"):format(count(books.dressed), count(books.placed)))
    local walkedComponents = false
    for _, w in ipairs(walks) do if w == "SkeletalMeshComponent" then walkedComponents = true end end
    check("finding a donor walks no list of every skeletal mesh component", not walkedComponents,
          table.concat(walks, ", "))

    -- A moment with no pawn of our own (one being replaced): nothing is dressed.
    hostPC.Pawn = nil
    Bodies.retry()
    local _, thirdMesh = remotePawn()
    UE.beginFrame(); Bodies.tick(t + 20)
    check("without a pawn of its own it dresses nobody", thirdMesh.SkeletalMeshAsset == nil,
          "a body went on while it could not tell whose pawn was whose")
    hostPC.Pawn = hostPawn

    _G.FindAllOf = realFindAllOf
    Config.DriveBodyAnimation = false
    H.world.objects["Player_Character_C"] = { hostPawn }
    Bodies.retry()
    UE.beginFrame()
end

-- ------------------------------------- 6c. a guest's local GameMode --

print("\n-- building a GameMode on a guest --")
local LocalGM = require("localgm")

-- A client is a world whose net driver HAS a ServerConnection, and a client
-- has no GameMode - that is the whole problem, so the fake must not have one.
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
H.world.objects["Core_Gamemode_C"] = {}
H.world.objects["GameModeBase"]    = {}

local builtGameMode = nil
H.spawn("GameStateBase", {
    GameModeClass = H.obj("Core_Gamemode_C", { __isActor = false }),
})

H.staticObjects["/Script/Engine.Default__GameplayStatics"] =
    H.obj("GameplayStatics", {
        __isActor = false,
        BeginDeferredActorSpawnFromClass = function()
            builtGameMode = H.obj("Core_Gamemode_C", {})
            return builtGameMode
        end,
        FinishSpawningActor = function() end,
    })

-- Opt-in since 1.7.0: off unless config.lua says GuestLocalGameMode = true.
LocalGM.init({})
UE.beginFrame()
LocalGM.tick(clock + 400)
LocalGM.tick(clock + 410)
check("is off unless asked for", builtGameMode == nil,
      "built a GameMode for a config that never mentions it - that starts a second game on the guest")

package.loaded["localgm"] = nil
LocalGM = require("localgm")
LocalGM.init({ GuestLocalGameMode = true })
UE.beginFrame()
LocalGM.tick(clock + 400)
check("waits for the level to settle before building one",
      builtGameMode == nil, "built one the instant it saw a pawn")

-- SETTLE is 5s and the pawn was first seen at 400.
UE.beginFrame()
LocalGM.tick(clock + 406)
check("builds a GameMode for a guest that has none",
      builtGameMode ~= nil, "no GameMode was built")
check("says why, in words a player can act on",
      logHas("No GameMode on this machine"), "fired silently")

builtGameMode = nil
UE.beginFrame()
LocalGM.tick(clock + 500)
check("never builds a second one", builtGameMode == nil, "built another")

-- Put the world back for the sections below.
H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["GameStateBase"] = {}
UE.beginFrame()

-- ------------------------- 6d. the channel over the game's connection --

print("\n-- host -> guest over PlayerController::ClientMessage --")
local Chan = require("rpcchan")

-- A remote player controller: on a listen server the guest's controller has a
-- Player (a UNetConnection) and is not the local one.
local sentStrings = {}
local badMsgType = nil
local rpcGuestPC = H.spawn("PlayerController", {
    Player        = H.obj("NetConnection", { __isActor = false }),
    ClientMessage = function(_, s, msgType)
        -- In the real game a Lua string here is a native access violation, not
        -- a Lua error: pcall cannot see it, the host just disappears.
        if type(msgType) ~= "table" or not msgType.__fname then
            badMsgType = type(msgType)
            return
        end
        sentStrings[#sentStrings + 1] = s
    end,
})
UE.beginFrame()

check("sends to a guest and not to the host",
      Chan.broadcast("state", { v1 = "55000" }) == 1,
      ("broadcast reached %d controller(s)"):format(#sentStrings))
check("passes the message type as an FName, never a Lua string",
      badMsgType == nil, "ClientMessage got a " .. tostring(badMsgType) ..
      " for its FName parameter - that crashes the host")
check("the payload is on the wire",
      (sentStrings[1] or ""):sub(1, 4) == "RT1|", sentStrings[1] or "<nothing sent>")

-- The receive half. The hook is what a guest runs when the host's RPC lands.
Chan.installReceiver()
check("installs a receiver on a hookable UFunction",
      H.hooks["/Script/Engine.PlayerController:ClientMessage"] ~= nil,
      "no hook was registered")

local heard = nil
Chan.on("state", function(fields) heard = fields end)
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, sentStrings[1])
Chan.pump()
check("a guest reads what the host sent", heard ~= nil and heard.v1 == "55000",
      "handler never fired with the payload")

-- Nothing may be applied inside the hook: it runs during the engine's packet
-- dispatch, where restyling NPCs raced an engine worker and crashed the
-- guest four times in 1.7.0's testing. The hook queues; pump() applies.
heard = nil
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, sentStrings[1])
check("a message is not applied inside the hook", heard == nil,
      "the handler ran during packet dispatch")
Chan.pump()
check("it is applied when the tick pumps the queue", heard ~= nil and heard.v1 == "55000",
      "pump() did not deliver it")

-- The hook sees every ClientMessage in the game, not only ours.
heard = nil
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, "You have died.")
Chan.pump()
check("ignores traffic that is not ours", heard == nil,
      "tried to parse an unrelated ClientMessage")

-- Upstream: guest -> host, over ServerSetSpectatorLocation. This is the half
-- that lets a guest pick anything up, and it never existed before - the old
-- path refused outright unless both players had typed the other's Steam ID
-- into config.lua.
local upSends = {}
hostPC.ServerSetSpectatorLocation = function(_, l, r)
    upSends[#upSends + 1] = { loc = l, rot = r }
end

check("a guest sends its aim upstream",
      Chan.sendUpstream({ X = 10, Y = 20, Z = 30 },
                        { Pitch = 5, Yaw = 90, Roll = 0 }) == 3,
      ("only %d send(s) accepted"):format(#upSends))
check("the aim survives the trip",
      (upSends[1] or {}).loc ~= nil and upSends[1].loc.X == 10
      and upSends[1].rot.Yaw == 90, "payload was mangled")

Chan.installUpstreamReceiver()
check("the host listens for it",
      H.hooks["/Script/Engine.PlayerController:ServerSetSpectatorLocation"] ~= nil,
      "no hook registered")

local interactions = 0
Chan.onUpstream(function() interactions = interactions + 1 end)
local upHook = H.hooks["/Script/Engine.PlayerController:ServerSetSpectatorLocation"]
for _ = 1, 3 do upHook(rpcGuestPC, upSends[1].loc, upSends[1].rot) end
Chan.pump()
-- 1.7.0: the pre-1.7.0 single "interact" packet (Roll 77.25) ran a trace and
-- called into Blueprint from inside the RPC hook; guestinput.lua replaces it.
check("the old single-interact packet is no longer acted on", interactions == 0,
      ("the host acted on it %d time(s)"):format(interactions))
check("our packets carry the marker", upSends[1].rot.Roll ~= 0,
      "Roll is 0 - indistinguishable from the engine's spectator sync")

-- A guest is a spectator for about a second while it logs in, and the engine
-- sends ServerSetSpectatorLocation by itself then (measured in 1.7.0). Those
-- must never be replayed as somebody pressing use.
interactions = 0
upHook(rpcGuestPC, { X = 1, Y = 2, Z = 3 }, { Pitch = 0, Yaw = 45, Roll = 0 })
Chan.pump()
check("the engine's own spectator updates are ignored", interactions == 0,
      "a spectator sync was treated as an interaction")

-- ------------------------------------- 6e. store state, host to guest --

print("\n-- store state: host to guest --")
-- Property names here are the real ones, read off the game's classes in
-- 1.7.0. The previous list named properties that do not exist, and this test
-- could not tell, because nothing checked what was actually sent.
local Sync = require("sync")
Sync.init(require("config"))     -- the rpc test above replaced the handler
sentStrings = {}
H.spawn("Core_Gamemode_C", { Money = 320960852, Level = 11, Experience = 7112,
                             ["Lifetime Experience"] = 7112, ["Store Value"] = 1089500 })
H.spawn("WeatherSystem_C", { Day = 3, Hour = 8, Minute = 15, Year = 1990, Season = 3,
                             DayTime = 1, ["Current Weather"] = 2, ["Day of the week"] = 6 })
UE.beginFrame()
Sync.tickHost(1000.0)
local wire = sentStrings[#sentStrings] or ""
check("the host sends money and the clock", wire:find("320960852", 1, true) ~= nil
      and wire:find("1990", 1, true) ~= nil, wire ~= "" and wire or "<nothing sent>")

-- Now be the guest: no GameMode, its own WeatherSystem running its own clock,
-- and a HUD widget to feed.
H.world.objects["Core_Gamemode_C"] = nil
H.world.objects["WeatherSystem_C"] = nil
local guestClock = H.spawn("WeatherSystem_C", { Day = 1, Hour = 22, Minute = 40,
    ["Stop or pause Timer - Add one minute"] = function(self) self.__stopped = true end,
    ["Update Lighting"] = function(self) self.__lit = (self.__lit or 0) + 1 end,
    ["Call Niagara System For Weather"] = function() end,
})
local hudCalls = {}
H.spawn("UI_Player_Interface_C", {
    ["Change Time"] = function(_, h, m) hudCalls.time = { h, m } end,
    ["Change Money Value"] = function(_, d, v) hudCalls.money = v end,
    ["Change Week Day"] = function(_, d) hudCalls.weekday = d end,
    ["Change XP Value"] = function(_, d, v) hudCalls.xp = v end,
})
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, wire)
Chan.pump()
check("the guest's clock shows the host's time",
      guestClock.Hour == 8 and guestClock.Minute == 15 and guestClock.Day == 3,
      ("guest clock reads day %s %s:%s"):format(tostring(guestClock.Day),
      tostring(guestClock.Hour), tostring(guestClock.Minute)))
check("the guest's own clock is stopped", guestClock.__stopped == true,
      "the guest's timer is still running and will drift")
-- The guest's own Update Lighting would fight the copied lights: its fill-
-- light lists are empty on a guest (measured), so it computes the wrong scene.
check("the guest's own lighting code is left alone", (guestClock.__lit or 0) == 0,
      "Update Lighting was called on the guest")
check("the HUD shows the host's time", hudCalls.time and hudCalls.time[1] == 8
      and hudCalls.time[2] == 15, "Change Time not called with 8:15")
check("the HUD shows the host's money", hudCalls.money == 320960852,
      tostring(hudCalls.money))
check("the HUD shows the host's XP", hudCalls.xp == 7112, tostring(hudCalls.xp))

hudCalls = {}
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, wire)
Chan.pump()
check("an unchanged value is not pushed twice", hudCalls.money == nil and hudCalls.time == nil,
      "the HUD was redrawn with identical numbers")
H.world.objects["WeatherSystem_C"] = nil
H.world.objects["UI_Player_Interface_C"] = nil
Sync.reset()

-- ------------------------------------ 6f. the store's look, host to guest --

print("\n-- store sign and expansions: host to guest --")
-- Level actors are matched by name across machines; in this fake each object
-- gets its own name, so the guest's copies are told to answer to the host's.
local World = require("worldsync")
World.init()
sentStrings = {}
local hostSign = H.spawn("StoreName_C", { Name = FText("VIDEO KING"),
    Color = { R = 1, G = 0.2, B = 0.6, A = 1 }, Size = 1.5 })
local boughtExp = H.spawn("StoreExpansion_C", { Unlocked = true })
local lockedExp = H.spawn("StoreExpansion_C", { Unlocked = false })
UE.beginFrame()
World.tickHost(2000.0)
local worldWire = sentStrings[#sentStrings] or ""
check("the host sends its sign and bought expansions",
      worldWire:find("VIDEO KING", 1, true) ~= nil
      and worldWire:find(boughtExp:GetFName():ToString(), 1, true) ~= nil
      and worldWire:find(lockedExp:GetFName():ToString(), 1, true) == nil,
      worldWire ~= "" and worldWire or "<nothing sent>")

local boughtName, lockedName = boughtExp:GetFName():ToString(), lockedExp:GetFName():ToString()
H.world.objects["StoreName_C"] = nil
H.world.objects["StoreExpansion_C"] = nil
local guestSign = H.spawn("StoreName_C", { Name = FText("RETRO REWIND"),
    ["Set StoreName Visual"] = function(self) self.__redrawn = true end })
local guestBought = H.spawn("StoreExpansion_C", { Unlocked = false,
    ["Unlock Expansion"] = function(self, instant) self.Unlocked = true self.__instant = instant end })
guestBought.GetFName = function() return FName(boughtName) end
local guestLocked = H.spawn("StoreExpansion_C", { Unlocked = false,
    ["Unlock Expansion"] = function(self) self.Unlocked = true end })
guestLocked.GetFName = function() return FName(lockedName) end

-- The guest receives it; on a server this handler deliberately does nothing,
-- so pretend to be a client for the call.
-- FText properties are written through KismetSystemLibrary SetTextPropertyByName
-- (UE.setText): a plain FText write overruns by 8 bytes on this build.
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = H.obj("KismetSystemLibrary", { __isActor = false,
    SetTextPropertyByName = function(_, obj, name, text) obj[name:ToString()] = text end })
UE._resetLookups()
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, worldWire)
Chan.pump()
H.theWorld.NetDriver.ServerConnection = nil
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = nil
UE._resetLookups()
UE.beginFrame()

check("the guest's sign reads the host's name",
      guestSign.Name and guestSign.Name:ToString() == "VIDEO KING" and guestSign.__redrawn == true,
      guestSign.Name and guestSign.Name:ToString() or "<nil>")
check("an expansion the host bought opens on the guest, instantly",
      guestBought.Unlocked == true and guestBought.__instant == true, "still locked")
check("one the host has not bought stays shut", guestLocked.Unlocked == false, "opened")
H.world.objects["StoreName_C"] = nil
H.world.objects["StoreExpansion_C"] = nil
World.reset()

-- ------------------------------------------- 6g. NPCs, host to guest --

print("\n-- NPC looks and animation: host to guest --")
local NpcSync = require("npcsync")
NpcSync.init({})
sentStrings = {}

-- A fake engine array, as UE4SS hands TArrays of structs to Lua.
local function tarray(items)
    return { ForEach = function(_, fn) for i, v in ipairs(items) do fn(i, { get = function() return v end }) end end }
end
local function asset(path)
    local o = H.obj("Asset", { __isActor = false })
    o.GetFullName = function() return "Texture2D " .. path end   -- H.obj sets its own
    return o
end
local shirt = asset("/Game/VideoStore/asset/character/NPC_M_02/NPC_04_Shirt_M_02_bc.NPC_04_Shirt_M_02_bc")
local function mid(parentPath, texture, tint)
    return H.obj("MaterialInstanceDynamic", { __isActor = false,
        Parent = asset(parentPath),
        TextureParameterValues = tarray(texture and { { ParameterInfo = { Name = FName("Base Color") }, ParameterValue = texture } } or {}),
        VectorParameterValues = tarray(tint and { { ParameterInfo = { Name = FName("Tint - Red Channel") }, ParameterValue = tint } } or {}),
    })
end
local hostMats = {
    [0] = mid("/Game/VideoStore/asset/character/NPC_M_01/MI_Skin.MI_Skin"),
    [1] = mid("/Game/VideoStore/asset/character/NPC_M_01/MI_Tshirt.MI_Tshirt", shirt, { R = 0.9, G = 0.3, B = 0.5, A = 1 }),
}
local hostNpc = H.spawn("AI_WalkBy_Character_C", {
    ["Current Task"] = 5, ["Sub Task"] = 1, ["Pick Up Level"] = 0,
    ["Has Basket"] = false, ["Is Holding something"] = false, ["Current Emotion"] = 2,
    K2_GetActorLocation = function() return { X = 1000, Y = 2000, Z = 90 } end,
    Mesh = H.obj("SkeletalMeshComponent", { __isActor = false,
        SkeletalMesh = asset("/Game/VideoStore/asset/character/NPC_M_02/SK_CHA_M_02.SK_CHA_M_02"),
        GetMaterial = function(_, i) return hostMats[i] end,
    }),
})
UE.beginFrame()
NpcSync.tickHost(3000.0)
local npcWire, lookWire = nil, nil
for _, w in ipairs(sentStrings) do
    if w:find("|npcs|", 1, true) then npcWire = w end
    if w:find("|npca|", 1, true) then lookWire = w end
end
check("the host sends where its NPCs are and what they are doing",
      npcWire ~= nil and npcWire:find("1000", 1, true) ~= nil, npcWire or "<no npcs message>")
check("the host sends an NPC's body, clothes and tint",
      lookWire ~= nil and lookWire:find("SK_CHA_M_02", 1, true) ~= nil
      and lookWire:find("NPC_04_Shirt_M_02_bc", 1, true) ~= nil and lookWire:find("0.900", 1, true) ~= nil,
      lookWire or "<no npca message>")

-- The guest: the same NPC arrived by replication, a few units off, wearing
-- the class defaults; another one far away must not be touched.
H.world.objects["AI_WalkBy_Character_C"] = nil
local applied = { mids = {} }
local guestNpc = H.spawn("AI_WalkBy_Character_C", {
    ["Current Task"] = 0,
    K2_GetActorLocation = function() return { X = 1030, Y = 1990, Z = 90 } end,
    Mesh = H.obj("SkeletalMeshComponent", { __isActor = false,
        SetSkinnedAssetAndUpdate = function(_, m, reinit) applied.mesh = m applied.reinit = reinit end,
        GetMaterial = function() return nil end,
        CreateDynamicMaterialInstance = function(_, i, parent, name)
            applied.creates = (applied.creates or 0) + 1
            if name and name.ToString and name:ToString() ~= "None" then applied.fixedName = name:ToString() end
            local m = H.obj("MaterialInstanceDynamic", { __isActor = false,
                SetTextureParameterValue = function(_, name, tex) applied.mids[i] = { name = name, tex = tex } end,
                SetVectorParameterValue = function(_, name, c) applied.tint = c end,
            })
            return m
        end,
    }),
})
local farNpc = H.spawn("AI_WalkBy_Character_C", {
    ["Current Task"] = 0,
    K2_GetActorLocation = function() return { X = 9000, Y = 9000, Z = 90 } end,
    Mesh = H.obj("SkeletalMeshComponent", { __isActor = false,
        SetSkinnedAssetAndUpdate = function() applied.wrong = true end }),
})
H.staticObjects["/Game/VideoStore/asset/character/NPC_M_02/SK_CHA_M_02.SK_CHA_M_02"] = asset("SK_CHA_M_02")
H.staticObjects["/Game/VideoStore/asset/character/NPC_M_01/MI_Tshirt.MI_Tshirt"] = asset("MI_Tshirt")
H.staticObjects["/Game/VideoStore/asset/character/NPC_M_01/MI_Skin.MI_Skin"] = asset("MI_Skin")
H.staticObjects["/Game/VideoStore/asset/character/NPC_M_02/NPC_04_Shirt_M_02_bc.NPC_04_Shirt_M_02_bc"] = shirt

H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, lookWire or "")
Chan.pump()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, npcWire or "")
Chan.pump()
H.theWorld.NetDriver.ServerConnection = nil
UE.beginFrame()

check("the nearest guest NPC animates from the host's state",
      guestNpc["Current Task"] == 5 and guestNpc["Current Emotion"] == 2,
      ("task %s"):format(tostring(guestNpc["Current Task"])))
check("it wears the host NPC's body", applied.mesh ~= nil, "SetSkinnedAssetAndUpdate not called")
check("and the pose is rebuilt for the new mesh", applied.reinit == true,
      "swapped without bReinitPose - the animation worker would walk the old mesh's pose buffers")
check("and its shirt texture and colour",
      applied.mids[1] ~= nil and applied.mids[1].tex == shirt and applied.tint ~= nil
      and math.abs((applied.tint.R or 0) - 0.9) < 0.01,
      "clothing slot 1 not rebuilt")
check("an NPC nowhere near is left alone", applied.wrong ~= true and farNpc["Current Task"] == 0,
      "the far NPC was restyled")
check("material instances are never created under a fixed name", applied.fixedName == nil,
      "created one named " .. tostring(applied.fixedName) .. " - a second apply would destroy the live one in place")

-- The host re-sends every look for late joiners. Re-applying an unchanged one
-- is how 1.7.0's first version crashed a guest; it must be a no-op.
local createsBefore = applied.creates or 0
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, lookWire or "")
Chan.pump()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, npcWire or "")
Chan.pump()
H.theWorld.NetDriver.ServerConnection = nil
UE.beginFrame()
check("an unchanged look sent again is not applied again", (applied.creates or 0) == createsBefore,
      ("%d more material instance(s) created"):format((applied.creates or 0) - createsBefore))

-- Garbage collection frees an asset once nothing uses it, and loading it again
-- makes a NEW object. A second NPC must get the new one: handing out a cached
-- pointer to the freed one is what crashed 1.7.0's guests seven times.
shirt.__dead = true
local shirt2 = asset("/Game/VideoStore/asset/character/NPC_M_02/NPC_04_Shirt_M_02_bc.NPC_04_Shirt_M_02_bc")
H.staticObjects["/Game/VideoStore/asset/character/NPC_M_02/NPC_04_Shirt_M_02_bc.NPC_04_Shirt_M_02_bc"] = shirt2
applied.mids = {}
local secondNpc = H.spawn("AI_WalkBy_Character_C", {
    ["Current Task"] = 0,
    K2_GetActorLocation = function() return { X = 1031, Y = 1991, Z = 90 } end,
    Mesh = guestNpc.Mesh,
})
guestNpc.__dead = true          -- the first one despawned
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, npcWire or "")
Chan.pump()
H.theWorld.NetDriver.ServerConnection = nil
UE.beginFrame()
check("an asset freed since it was last used is never handed out again",
      applied.mids[1] ~= nil and applied.mids[1].tex == shirt2,
      applied.mids[1] and "got the freed texture" or "the second NPC was not restyled")
H.world.objects["AI_WalkBy_Character_C"] = nil
NpcSync.reset()

-- ------------------------- 6g'. what a guest's NPC never builds for itself --
-- MEASURED in 1.7.0: a guest's NPC never finishes its own start-up (Bind
-- Init waits for a GameMode, forever), so it glided with its walk frozen
-- (Character Scale 0 divides the play rate), was bald (the hair sat on the
-- capsule's centre), wore the default face, showed a thought bubble on every
-- NPC in town - and the guest's own AI Director spawned frozen extras.
do
    print("\n-- NPC size, hair, face, bubble and badge: host to guest --")
    sentStrings = {}
    UE._resetLookups()
    local P = "/Game/VideoStore/asset/character/"
    local function dyn(parentPath, vectors, scalars)
        local vec, sca = {}, {}
        for name, c in pairs(vectors or {}) do vec[#vec + 1] = { ParameterInfo = { Name = FName(name) }, ParameterValue = c } end
        for name, v in pairs(scalars or {}) do sca[#sca + 1] = { ParameterInfo = { Name = FName(name) }, ParameterValue = v } end
        return H.obj("MaterialInstanceDynamic", { __isActor = false, Parent = asset(P .. parentPath),
            TextureParameterValues = tarray({}), VectorParameterValues = tarray(vec), ScalarParameterValues = tarray(sca) })
    end
    local paths = {
        body  = P .. "NPC_M_01/SK_CHA_M_01.SK_CHA_M_01",
        skin  = "NPC_M_01/MI_CHA_M-01_Skin_01.MI_CHA_M-01_Skin_01",
        mouth = "face/MI_CHA_Face_Mouth-01.MI_CHA_Face_Mouth-01",
        eye   = "face/MI_CHA_Face_Eye-01.MI_CHA_Face_Eye-01",
        hair  = P .. "mesh/hair/NPC_Hair_M_04.NPC_Hair_M_04",
        brown = "hair/MI_CHA_Hair_Brown.MI_CHA_Hair_Brown",
        icon  = "/Game/VideoStore/asset/prop/Popcorn/T_UI_Popcorn-Request_Normal.T_UI_Popcorn-Request_Normal",
    }
    local tone = { R = 0.6, G = 0.41, B = 0.21 }
    local hostMat = {
        [0] = dyn(paths.skin),
        [5] = dyn(paths.mouth, nil, { Frame = 0.96 }),
        [6] = dyn(paths.eye, { ["Skin Tone"] = tone }),
        [7] = dyn(paths.eye, { ["Skin Tone"] = tone }),
    }
    local hairColour = dyn(paths.brown)
    local icon = asset(paths.icon)
    H.spawn("AI_Employee_Character_C", {
        ["Current Task"] = 2, ["Sub Task"] = 3, ["Pick Up Level"] = 0, ["Has Basket"] = false,
        ["Is Holding something"] = false, ["Current Emotion"] = 7,
        ["Character Scale"] = 0.996, ["Max Speed Walk Scale"] = 0.8,
        ["Eyelid Base Height"] = { X = 0.155, Y = -0.144, Z = 0.0 },
        ["Client Name"] = FText("Adam"),
        K2_GetActorLocation = function() return { X = 1734, Y = -1482, Z = 90 } end,
        Mesh = H.obj("SkeletalMeshComponent", { __isActor = false,
            SkeletalMesh = asset(paths.body),
            GetNumMaterials = function() return 8 end,
            GetMaterial = function(_, i) return hostMat[i] end }),
        Hair = H.obj("StaticMeshComponent", { __isActor = false,
            IsVisible = function() return true end,
            StaticMesh = asset(paths.hair),
            GetMaterial = function(_, i) if i == 0 then return hairColour end end }),
        -- Rolled without a beard: the host's Blueprint DESTROYS the component.
        ["Facial-Hair"] = H.obj("StaticMeshComponent", { __isActor = false, __dead = true }),
        Bubble_Anchor = H.obj("SceneComponent", { __isActor = false, RelativeLocation = { X = 0, Y = 43.8, Z = 62.2 } }),
        Widget3D_QuestRequest = H.obj("WidgetComponent", { __isActor = false,
            IsVisible = function() return true end,
            GetWidget = function() return { Front = { Brush = { ResourceObject = icon } } } end }),
    })
    UE.beginFrame()
    NpcSync.tickHost(5000.0)
    local stateWire, lookWire2 = nil, nil
    for _, w in ipairs(sentStrings) do
        if w:find("|npcs|", 1, true) then stateWire = w end
        if w:find("|npca|", 1, true) then lookWire2 = w end
    end
    check("the host sends what a guest's NPC cannot work out: size, walk rate, eyelids, badge",
          lookWire2 ~= nil and lookWire2:find("cs=0.996", 1, true) ~= nil and lookWire2:find("ws=0.800", 1, true) ~= nil
          and lookWire2:find("eb=0.155,-0.144", 1, true) ~= nil and lookWire2:find("nm=Adam", 1, true) ~= nil,
          lookWire2 or "<no npca message>")
    local noBeard = lookWire2 ~= nil and (lookWire2:find("|f=|", 1, true) ~= nil or lookWire2:match("|f=$") ~= nil)
    check("and the hair with its colour, the face's materials, and no beard",
          noBeard and lookWire2:find("NPC_Hair_M_04", 1, true) ~= nil
          and lookWire2:find("MI_CHA_Hair_Brown", 1, true) ~= nil and lookWire2:find("MI_CHA_Face_Mouth-01", 1, true) ~= nil,
          lookWire2 or "<no npca message>")
    check("its state says the thought bubble is up, and with which icon",
          stateWire ~= nil and stateWire:find(",7,1," .. paths.icon, 1, true) ~= nil, stateWire or "<no npcs message>")

    -- The guest's copy: the class defaults, Role SimulatedProxy, nothing built.
    H.world.objects["AI_Employee_Character_C"] = nil
    for _, k in ipairs({ "skin", "mouth", "eye", "brown" }) do H.staticObjects[P .. paths[k]] = asset(P .. paths[k]) end
    for _, k in ipairs({ "body", "hair", "icon" }) do H.staticObjects[paths[k]] = asset(paths[k]) end
    local got = { creates = 0, params = {}, morph = {} }
    local guestMat = {}
    local function guestMid(slot, parent)
        return H.obj("MaterialInstanceDynamic", { __isActor = false, Parent = parent,
            SetTextureParameterValue = function() end,
            SetVectorParameterValue = function(_, n, c) got.params[slot .. ":" .. n:ToString()] = c end,
            SetScalarParameterValue = function(_, n, v) got.params[slot .. ":" .. n:ToString()] = v end })
    end
    local FACE = { Mouth = 5, EyeL = 6, EyeR = 7 }
    local guestStaff = H.spawn("AI_Employee_Character_C", {
        Role = 1, ["Character Scale"] = 0.0, ["Max Speed Walk Scale"] = 1.0, ["Current Task"] = 0,
        K2_GetActorLocation = function() return { X = 1736, Y = -1480, Z = 90 } end,
        K2_DestroyActor = function() got.wronglyRemoved = true end,
        Mesh = H.obj("SkeletalMeshComponent", { __isActor = false,
            SetSkinnedAssetAndUpdate = function() end,
            GetMaterialIndex = function(_, n) return FACE[n:ToString()] or -1 end,
            GetMaterial = function(_, i) return guestMat[i] end,
            CreateDynamicMaterialInstance = function(_, i, parent)
                got.creates = got.creates + 1
                guestMat[i] = guestMid(i, parent)
                return guestMat[i]
            end,
            SetWorldScale3D = function(_, v) got.scale = v end,
            SetMorphTarget = function(_, n, v) got.morph[n:ToString()] = v end }),
        Hair = H.obj("StaticMeshComponent", { __isActor = false,
            SetStaticMesh = function(_, m) got.hairMesh = m end,
            SetVisibility = function(_, v) got.hairShown = v end,
            GetMaterial = function() return nil end,
            CreateDynamicMaterialInstance = function(_, i, parent) got.hairColour = parent return guestMid("hair" .. i, parent) end }),
        ["Facial-Hair"] = H.obj("StaticMeshComponent", { __isActor = false,
            SetVisibility = function(_, v) got.beardShown = v end }),
        ["Attach Child to Skeletal"] = function() got.attached = (got.attached or 0) + 1 end,
        Bubble_Anchor = H.obj("SceneComponent", { __isActor = false, RelativeLocation = { X = 0, Y = 43.8, Z = 62.8 },
            K2_SetRelativeLocation = function(self, v) self.RelativeLocation = v got.anchorZ = v.Z end,
            K2_SetWorldRotation = function(_, r) got.turn = r end }),
        Widget3D_QuestRequest = H.obj("WidgetComponent", { __isActor = false,
            SetVisibility = function(_, v) got.bubble = v end,
            GetWidget = function() return { Front = { SetBrushFromTexture = function(_, t) got.icon = t end } } end }),
        Staff_NameSticker = H.obj("ChildActorComponent", { __isActor = false,
            ChildActor = H.obj("Staff_NameSticker_C", { ["Update Staff Name"] = function(_, n) got.badge = n end }) }),
    })
    local function deliver(...)
        H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
        UE.beginFrame()
        for _, wire in ipairs({ ... }) do
            H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, wire)
            Chan.pump()
        end
    end
    deliver(lookWire2 or "", stateWire or "")
    check("a guest's NPC gets the host's size, so its walk is no longer divided by zero",
          math.abs((guestStaff["Character Scale"] or 0) - 0.996) < 0.001 and got.scale ~= nil
          and math.abs((got.scale.X or 0) - 0.996) < 0.001 and math.abs((guestStaff["Max Speed Walk Scale"] or 0) - 0.8) < 0.001,
          ("scale %s, walk %s"):format(tostring(guestStaff["Character Scale"]), tostring(guestStaff["Max Speed Walk Scale"])))
    check("its bubble rides at the host's height, set once", math.abs((got.anchorZ or 0) - 62.2) < 0.01,
          tostring(got.anchorZ))
    check("its hair is put on, in the host's colour, and onto the head",
          got.hairMesh ~= nil and got.hairShown == true and got.hairColour ~= nil and (got.attached or 0) >= 1,
          ("mesh %s shown %s colour %s attached %s"):format(tostring(got.hairMesh), tostring(got.hairShown),
              tostring(got.hairColour), tostring(got.attached)))
    check("a beard the host's NPC was rolled without is hidden", got.beardShown == false, tostring(got.beardShown))
    check("its mouth and face show the host's emotion",
          math.abs((got.params["5:Frame"] or -1) - 0.96) < 0.001 and math.abs((got.morph.Surprised or 9) + 0.2) < 0.001
          and math.abs((got.morph.Angry or 9) - 0.3) < 0.001,
          ("frame %s surprised %s angry %s"):format(tostring(got.params["5:Frame"]), tostring(got.morph.Surprised),
              tostring(got.morph.Angry)))
    local lid = got.params["6:Eyelid"]
    check("its eyes are open at the host's height, in its skin tone",
          lid ~= nil and math.abs(lid.R - 0.155) < 0.001 and math.abs(lid.G + 0.144) < 0.001
          and got.params["7:Eyelid"] ~= nil and got.params["6:Skin Tone"] ~= nil, lid and "" or "no eyelid set")
    check("its thought bubble is up, with the host's icon", got.bubble == true and got.icon == H.staticObjects[paths.icon],
          ("shown %s icon %s"):format(tostring(got.bubble), tostring(got.icon)))
    check("a member of staff wears the name the host gave them",
          got.badge ~= nil and got.badge.__fname == true and got.badge:ToString() == "Adam", tostring(got.badge))

    -- The host's NPC turns its bubble to its player every tick; the guest's
    -- copy has no tick of its own, so the guest turns it to the guest.
    local me = UE.vec(UE.GetPawn() and UE.GetPawn():K2_GetActorLocation())
    NpcSync.tickGuest(6000.0)
    local want = me and math.deg(math.atan(me.Y - (-1480), me.X - 1736)) or nil
    check("a bubble that is up is turned to the guest",
          want ~= nil and got.turn ~= nil and math.abs((got.turn.Yaw or 999) - want) < 0.5 and got.turn.pitch ~= nil,
          ("turned to %s, wanted %s"):format(tostring(got.turn and got.turn.Yaw), tostring(want)))

    -- The emotion changes and the bubble closes: the face is re-drawn, the
    -- look is not rebuilt.
    local createsBefore = got.creates
    local calmer = (stateWire or ""):gsub(",7,1,[^;|]*", ",1,0,")
    deliver(calmer)
    check("a new emotion re-draws only the face",
          math.abs((got.params["5:Frame"] or -1) - 0.24) < 0.001 and got.creates == createsBefore,
          ("frame %s, %d material(s) created"):format(tostring(got.params["5:Frame"]), got.creates - createsBefore))
    check("a bubble the host closes closes on the guest", got.bubble == false, tostring(got.bubble))

    -- The guest's own AI Director: its spawn timer stopped, its NPCs removed.
    UE._resetLookups()
    local timerOn, cleared, removed = true, nil, 0
    local director = H.spawn("AI_Director_C", {})
    local ksl = H.obj("KismetSystemLibrary", { __isActor = false,
        K2_IsTimerActive = function(_, o, name) return o == director and name == "Event - Timer" and timerOn end,
        K2_ClearTimer = function(_, o, name) if o == director then cleared = name timerOn = false end end })
    H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = ksl
    H.spawn("AI_WalkBy_Character_C", { Role = 3,
        K2_GetActorLocation = function() return { X = 4637, Y = -1148, Z = 200 } end,
        K2_DestroyActor = function(self) self.__dead = true removed = removed + 1 end })
    UE.beginFrame()
    NpcSync.tickGuest(6010.0)
    check("a guest stops its own AI Director spawning NPCs", cleared == "Event - Timer", tostring(cleared))
    check("and removes the NPCs its own game spawned, never the host's",
          removed == 1 and got.wronglyRemoved ~= true, ("%d removed, host's removed: %s"):format(removed, tostring(got.wronglyRemoved)))

    ksl.__dead = true
    H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = nil
    for _, cls in ipairs({ "AI_Employee_Character_C", "AI_WalkBy_Character_C", "AI_Director_C" }) do H.world.objects[cls] = nil end
    H.theWorld.NetDriver.ServerConnection = nil
    NpcSync.reset()
    UE._resetLookups()
    UE.beginFrame()
end

-- --------------------------------------- 6h. a guest's presses, upstream --

print("\n-- guest actions: guest to host --")
local actions = {}
Chan.onAction(function(pc, code, loc, rot) actions[#actions + 1] = { pc = pc, code = code, loc = loc, rot = rot } end)
upSends = {}
check("a guest sends an action with its camera",
      Chan.sendAction(2, { X = 2075, Y = -1190, Z = 156 }, { Pitch = -9, Yaw = 180, Roll = 0 }) == 2,
      ("only %d send(s)"):format(#upSends))
check("the action rides in Roll, away from 0 and the legacy mark",
      upSends[1] and math.abs(upSends[1].rot.Roll - 102) < 0.001, tostring(upSends[1] and upSends[1].rot.Roll))
check("the pitch rides too, in the casing the engine reads",
      upSends[1] and upSends[1].rot.pitch == -9 and upSends[1].rot.Pitch == -9,
      upSends[1] and ("pitch=%s Pitch=%s"):format(tostring(upSends[1].rot.pitch),
                                                  tostring(upSends[1].rot.Pitch)))

for _, s_ in ipairs(upSends) do upHook(rpcGuestPC, s_.loc, s_.rot) end
Chan.pump()
check("the host decodes it once (sent twice, unreliable)", #actions == 1 and actions[1].code == 2,
      ("%d action(s), code %s"):format(#actions, tostring(actions[1] and actions[1].code)))
check("the camera survives the trip", actions[1] and actions[1].loc.X == 2075 and actions[1].rot.Yaw == 180,
      "location or rotation mangled")
upHook(rpcGuestPC, { X = 1, Y = 2, Z = 3 }, { Pitch = 0, Yaw = 10, Roll = 0 })
Chan.pump()
check("the engine's own spectator sync is still not an action", #actions == 1,
      ("%d action(s)"):format(#actions))

-- Without the native helper, GetPlayerController(0) would hand the guest's
-- tape to the HOST. Refusing is the only correct thing to do.
local GuestInput = require("guestinput")
local fired = 0
local guestPawnForReplay = H.spawn("Player_Character_C", {
    ["InpActEvt_Input_Secondary-Trigger_K2Node_EnhancedInputActionEvent_23"] = function() fired = fired + 1 end,
    ["InpActEvt_Input_Main-Trigger_K2Node_EnhancedInputActionEvent_20"] = function() fired = fired + 1 end,
    ["Look At Test"] = function() end,
})
rpcGuestPC.Pawn = guestPawnForReplay
GuestInput.init({})
UE.beginFrame()
-- Code 1 (LMB): a different action from the one above, so the double-send
-- collapse cannot be what stops it.
upHook(rpcGuestPC, { X = 10, Y = 20, Z = 30 }, { Pitch = 0, Yaw = 0, Roll = 101 })
Chan.pump()
check("with no native helper a guest's press is refused, not given to the host",
      fired == 0 and logHas("without RewindNative.dll"),
      ("the event fired %d time(s) with nothing redirecting player 0"):format(fired))
rpcGuestPC.Pawn = nil
for i, o in ipairs(H.world.objects["Player_Character_C"] or {}) do
    if o == guestPawnForReplay then table.remove(H.world.objects["Player_Character_C"], i) break end
end
UE.beginFrame()

-- -------------------- 6i. a guest's HUD: what they hold and look at --

print("\n-- guest HUD: what they hold and look at (the GameMode stand-in) --")
-- The DLL cannot run here: native\RewindNative\test_standin.cpp (run by
-- build.bat) tests its half - when it answers and when it must not. This is
-- the Lua half: the right objects, handed over by address, kept armed, stood
-- down and let go of before a map unloads, and switched off for good when a
-- run dies while it is unproven. In a block: the main chunk is at Lua's
-- limit of 200 locals.
do
local Native   = require("native")
local hudCfg   = require("config")
-- The feature on probation, as this copy's crash record says (safety.lua).
local function recordProbation()
    local file = require("safety")._state().file
    local fh = file and io.open(file, "r")
    if not fh then return nil end
    local op = nil
    for line in fh:lines() do
        if line == "end" then break end
        op = op or line:match("^probation (.+)$")
    end
    fh:close()
    return op
end
local GM_DEFAULT  = "/Game/VideoStore/core/gamemode/Core_Gamemode.Default__Core_Gamemode_C"
local UI_IFACE    = "/Game/VideoStore/core/blueprint/interface/Interface/UI_Interface.UI_Interface_C"
local HUD_LIBRARY = "/Game/VideoStore/core/blueprint/function/UI_Player_Interface.UI_Player_Interface_C"
local GETGAMEMODE = "/Script/Engine.GameplayStatics:GetGameMode"

local function addressed(className, addr)
    local o = H.obj(className, { __isActor = false })
    o.GetAddress = function() return addr end
    return o
end
local function fakeProp(name, offset, cls)
    return { GetFName = function() return FName(name) end,
             GetPropertyClass = function() return cls end,
             GetOffset_Internal = function() return offset end }
end
local function fileLine(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local l = fh:read("l")
    fh:close()
    return l
end
local function logSince(mark, pattern)
    for i = mark + 1, #H.log do
        if H.log[i]:find(pattern, 1, true) then return true end
    end
    return false
end

-- Core_Gamemode_C's layout as the header dump has it: UberGraphFrame 0x328,
-- "UI Game Interface" 0x338.
H.staticObjects[UE.Paths.GameMode] = H.obj("BlueprintGeneratedClass", {
    __isActor = false,
    ForEachProperty = function(_, fn)
        fn(fakeProp("UberGraphFrame", 0x328))
        fn(fakeProp("Actor Gatherer", 0x330))
        fn(fakeProp("UI Game Interface", 0x338, H.obj("WidgetBlueprintGeneratedClass", { __isActor = false })))
    end,
})
local gmDefault = addressed("Core_Gamemode_C", 0x5000)
H.staticObjects[GM_DEFAULT]  = gmDefault
H.staticObjects[UI_IFACE]    = addressed("Class", 0x6100)
H.staticObjects[HUD_LIBRARY] = addressed("BlueprintGeneratedClass", 0x6200)
H.staticObjects[GETGAMEMODE] = addressed("Function", 0x6300)

-- RewindNative.dll as the Lua side sees it.
local dll = {}
local function fakeDll(withStandIn)
    dll.arms, dll.hooks, dll.disarms, dll.armed, dll.handed, dll.reply = {}, {}, 0, false, 0, 1
    local e = {
        rt_version = function() return 2, "RewindNative (fake)" end,
        rt_hook_return = function() return 0xD8 end,
        rt_redirect_begin = function() return 0 end,
        rt_redirect_end = function() return 0 end,
        rt_unhook_all = function() return 0 end,
        rt_stats = function() return #dll.hooks, 0xD8, 0, 0 end,
        rt_read_ptr = function() return nil end,
    }
    if withStandIn then
        e.rt_hook_null = function(addr) dll.hooks[#dll.hooks + 1] = addr return 0xD8 end
        e.rt_standin_arm = function(...)
            dll.arms[#dll.arms + 1] = { ... }
            dll.armed = dll.reply == 1
            return dll.reply
        end
        e.rt_standin_disarm = function() dll.disarms = dll.disarms + 1 dll.armed = false return dll.handed end
        e.rt_standin_stats = function() return dll.armed and 1 or 0, 0, 0, dll.handed, 0 end
    end
    Native._fake(e)
end

-- A fresh hud.lua each time: what it decided in one case must not leak into
-- the next. main.lua keeps the one it booted with.
local hudT = 5000
local function freshHud()
    package.loaded["hud"] = nil
    local m = require("hud")
    m.init(hudCfg)
    return m
end
local function hudTicks(m, n, step)
    for _ = 1, n do
        hudT = hudT + step
        UE.beginFrame()
        m.tick(hudT)
    end
end
local function settled(m)
    hudTicks(m, 1, 1.0)       -- the pawn is seen
    hudTicks(m, 1, 9.0)       -- SETTLE later the HUD is found, then the stand-in
end

local guestConn = H.obj("NetConnection", { __isActor = false })
H.theWorld.NetDriver.ServerConnection = guestConn
local guestWidget = H.spawn("UI_Player_Interface_C", { GetAddress = function() return 0x7000 end })

fakeDll(true)
hudCfg.GuestHudDetails = nil          -- an old config.lua that never mentions it: on
local HudA = freshHud()
settled(HudA)
local a = dll.arms[1]
check("a guest's HUD wraps GetGameMode", dll.hooks[1] == 0x6300, tostring(dll.hooks[1]))
check("and arms the stand-in with the GameMode default, the widget, their offsets, the interface and the library",
      a ~= nil and a[1] == 0x5000 and a[2] == 0x7000 and a[3] == 0x328 and a[4] == 0x338
      and a[5] == 0x6100 and a[6] == 0x6200,
      a and table.concat(a, ", ") or "never armed")
check("the GameMode default now holds the guest's widget", gmDefault["UI Game Interface"] == guestWidget,
      tostring(gmDefault["UI Game Interface"]))
check("it is on probation while unproven", recordProbation() ~= nil, "not on probation in the record")
check("rt.native says it is armed", table.concat(Native.status(), "\n"):find("HUD stand-in: ARMED", 1, true) ~= nil,
      table.concat(Native.status(), " | "))

local armsBefore = #dll.arms
hudTicks(HudA, 3, 1.0)
check("an armed stand-in is left alone", #dll.arms == armsBefore, ("%d more arm(s)"):format(#dll.arms - armsBefore))
dll.armed = false                     -- the DLL stood down: something it relied on stopped being live
hudTicks(HudA, 3, 1.0)
check("one the DLL stood down is armed again", #dll.arms == armsBefore + 1,
      ("%d arm(s) since"):format(#dll.arms - armsBefore))

dll.handed = 40
hudTicks(HudA, 3, 1.0)
check("off probation once it has answered enough HUD calls",
      recordProbation() == nil and logHas("off probation"), "still on probation in the record")

-- What is in the guest's hands. The pick-up runs on the host; on the guest
-- only the attachment arrives (measured), so the pawn's own Set Object Hold -
-- which draws the product panel - is called to match the hand socket.
UE.beginFrame()
local myPawn = UE.GetPawn()
local handChildren, holdCalls = {}, {}
local socket = H.obj("SceneComponent", { __isActor = false,
    GetNumChildrenComponents = function() return #handChildren end,
    GetChildComponent = function(_, i) return handChildren[i + 1] end,
})
myPawn["AttachObject Socket"] = socket
myPawn["Set Object Hold"] = function(self, ...)
    holdCalls[#holdCalls + 1] = { n = select("#", ...), obj = (...) }
    self["Object Hold"] = (...)
end
local heldTape = H.spawn("videotape_C", {})
handChildren[1] = H.obj("SceneComponent", { __isActor = false, GetOwner = function() return heldTape end })
hudTicks(HudA, 2, 1.0)
check("a guest whose hand socket holds a tape has it set as the pawn's Object Hold",
      #holdCalls == 1 and holdCalls[1].obj == heldTape, ("%d call(s)"):format(#holdCalls))
hudTicks(HudA, 3, 1.0)
check("and only once while nothing changes", #holdCalls == 1, ("%d call(s)"):format(#holdCalls))
handChildren[1] = nil
hudTicks(HudA, 2, 1.0)
check("an emptied hand clears it, passing an explicit null",
      #holdCalls == 2 and holdCalls[2].obj == nil and holdCalls[2].n == 1,
      holdCalls[2] and ("%d argument(s)"):format(holdCalls[2].n) or "not cleared")
dll.armed, dll.reply = false, -2      -- stood down, and refusing for now
handChildren[1] = H.obj("SceneComponent", { __isActor = false, GetOwner = function() return heldTape end })
hudTicks(HudA, 3, 1.0)
check("without an armed stand-in the pawn is left alone", #holdCalls == 2, ("%d call(s)"):format(#holdCalls))
dll.reply = 1
hudTicks(HudA, 3, 1.0)                -- re-armed by the check
myPawn["AttachObject Socket"], myPawn["Set Object Hold"], myPawn["Object Hold"] = nil, nil, nil
H.world.objects["videotape_C"] = nil

local disarmsBefore = dll.disarms
H.loadMapHooks[#H.loadMapHooks]()
check("a map load stands it down before the world goes", dll.disarms == disarmsBefore + 1 and not dll.armed,
      ("%d disarm(s)"):format(dll.disarms - disarmsBefore))
check("and lets go of the widget on the GameMode default", gmDefault["UI Game Interface"] == nil,
      "the GameMode default still holds the old world's widget")

-- The host: a real GameMode, nothing to stand in for.
H.theWorld.NetDriver.ServerConnection = nil
fakeDll(true)
local HudE = freshHud()
settled(HudE)
check("the host never arms it", #dll.arms == 0 and #dll.hooks == 0, ("%d arm(s)"):format(#dll.arms))
H.theWorld.NetDriver.ServerConnection = guestConn

local mark = #H.log
fakeDll(true)
hudCfg.GuestHudDetails = false
local HudF = freshHud()
settled(HudF)
hudTicks(HudF, 3, 9.0)
check("Config.GuestHudDetails = false keeps it off", #dll.arms == 0 and #dll.hooks == 0
      and logSince(mark, "GuestHudDetails = false"), ("%d arm(s)"):format(#dll.arms))
hudCfg.GuestHudDetails = true

mark = #H.log
fakeDll(false)
local HudG = freshHud()
settled(HudG)
hudTicks(HudG, 3, 9.0)
check("an older RewindNative.dll still loads and says why there are no details",
      logSince(mark, "older than the mod") and gmDefault["UI Game Interface"] == nil,
      "no explanation, or the GameMode default was touched")
check("and says so once", (function()
    local n = 0
    for i = mark + 1, #H.log do if H.log[i]:find("older than the mod", 1, true) then n = n + 1 end end
    return n
end)() == 1, "repeated")

mark = #H.log
fakeDll(true)
dll.reply = -3                        -- the GameMode default has no event frame: cannot change
local HudH = freshHud()
settled(HudH)
check("a refusal that cannot change ends it", #dll.arms == 1 and logSince(mark, "no event frame"),
      ("%d arm(s)"):format(#dll.arms))
check("and lets go of the widget again", gmDefault["UI Game Interface"] == nil, "still pointed at the widget")
check("and does not leave it on probation", recordProbation() == nil, "left on probation")
hudTicks(HudH, 5, 30.0)
check("and never tries again", #dll.arms == 1, ("%d arm(s)"):format(#dll.arms))

-- A run that dies while the stand-in is unproven, with the engine running
-- (between ticks): nothing takes it off probation.
fakeDll(true)
local HudI = freshHud()
settled(HudI)
local op = recordProbation()
check("armed on probation", op ~= nil and dll.armed, "not armed, or not on probation")
local S6 = require("safety")
S6.phase(S6.IDLE)
-- The next launch comes long after the dead run's last write.
local deadRecord = S6._state().file
S6._forget()
do
    local fh = io.open(deadRecord, "r")
    local text = fh:read("a")
    fh:close()
    fh = io.open(deadRecord, "w")
    fh:write((text:gsub("beat %d+", "beat " .. (os.time() - 120))))
    fh:close()
end
S6.init()
S6.settle(nil)                        -- no crash-report check here: blamed as before
local crashedOp = S6._state().crashedOn
check("a run that died on probation switches it off at the next launch",
      op ~= nil and crashedOp == op and S6.isBlocked(op), tostring(crashedOp))
mark = #H.log
fakeDll(true)
local HudI2 = freshHud()
settled(HudI2)
check("and it stays off, saying why", #dll.arms == 0 and logSince(mark, "switched off after an earlier crash")
      and gmDefault["UI Game Interface"] == nil, ("%d arm(s)"):format(#dll.arms))
S6.reset()

-- Put the world back for the sections below.
Native._fake(nil)
hudCfg.GuestHudDetails = true
H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["UI_Player_Interface_C"] = nil
for _, p in ipairs({ UE.Paths.GameMode, GM_DEFAULT, UI_IFACE, HUD_LIBRARY, GETGAMEMODE }) do
    H.staticObjects[p] = nil
end
UE.beginFrame()
end

-- ------------------------------------------------- 7. crash breadcrumbs --
-- The record of what is in flight (safety.lua). What went wrong first, with two
-- copies of the game on one PC: a guest crashed inside "giving other players
-- a visible body", the host - same folder - deleted the shared breadcrumb on
-- its next guarded call, and the guest's next launch switched off the HUD
-- stand-in, which had merely been on probation.

print("\n-- crash breadcrumbs --")
do
local S = require("safety")
local BODIES  = "giving other players a visible body (Config.BorrowNpcBodies)"
local STANDIN = "showing a guest what they hold and look at (the HUD stand-in)"

local function slotFile(n) return ("RewindTogether-inflight.%d.txt"):format(n) end
local function readFile(p)
    -- Text mode: the record is written in text mode, so CRLF on Windows.
    local fh = io.open(p, "r")
    if not fh then return nil end
    local s = fh:read("a")
    fh:close()
    return s
end
local function writeFile(p, s)
    local fh = io.open(p, "wb")
    fh:write(s)
    fh:close()
end
local function clean()
    S._forget()
    for _, f in ipairs({ "RewindTogether-disabled.txt", "RewindTogether-inprogress.txt",
                         "RewindTogether-probation.txt" }) do os.remove(f) end
    for n = 1, 4 do os.remove(slotFile(n)) end
end
-- A record as a copy of the game leaves it; `beat` defaults to two minutes ago.
local function record(t)
    local lines = { "rt-inflight 1", "token " .. (t.token or "-"),
                    "beat " .. (t.beat or (os.time() - 120)), "phase " .. (t.phase or "-") }
    if t.probation then
        lines[#lines + 1] = "probation " .. t.probation
        for _, p in ipairs(t.probationPhases or {}) do lines[#lines + 1] = "probation-phase " .. p end
    end
    for _, g in ipairs(t.guards or {}) do lines[#lines + 1] = "guard " .. g end
    lines[#lines + 1] = "end"
    return table.concat(lines, "\n") .. "\n"
end
-- This process, as Safety sees it: two engine objects that live as long as
-- the process does. A new launch gets new addresses.
local gsCdo = H.staticObjects["/Script/Engine.Default__GameplayStatics"]
local gsAddress = gsCdo and gsCdo.GetAddress
local function launch(a, b)
    H.staticObjects["/Script/CoreUObject.Default__Object"] =
        H.obj("Object", { __isActor = false, GetAddress = function() return a end })
    if gsCdo then gsCdo.GetAddress = function() return b end end
    return ("%x-%x"):format(a, b)
end
local function since(m, pattern)
    for i = m + 1, #H.log do if H.log[i]:find(pattern, 1, true) then return true end end
    return false
end

clean()
launch(0x1000, 0x2000)
S.init()
local mine = S._state()
check("a copy of the game keeps its own record", mine.slot == 1 and readFile(slotFile(1)) ~= nil,
      tostring(mine.slot))

local during = nil
local ran, result = S.guard("pretend-risky", function()
    during = readFile(mine.file)
    return "done"
end)
check("guard runs and returns", ran and result == "done", tostring(result))
check("the record names it while it runs, on disk before it starts",
      during ~= nil and during:find("guard pretend-risky", 1, true) ~= nil, during)
local live = readFile(mine.file):match("^(.-)\nend\n") or ""
check("and not once it has returned", live ~= "" and not live:find("guard pretend-risky", 1, true), live)

local inner = nil
S.guard("outer op", function()
    S.guard("inner op", function() end)
    inner = readFile(mine.file)
end)
check("guards nest: an inner one returning puts the outer one back (the first version lost it)",
      inner ~= nil and inner:find("guard outer op\nend", 1, true) ~= nil, inner)

S.phase("Bodies.tick")
check("the tick phase is in the record", readFile(mine.file):find("phase Bodies.tick", 1, true) ~= nil,
      readFile(mine.file))

-- A crash inside a guard: what is on disk at that moment is what the next
-- launch reads.
local atCrash = nil
S.guard("pretend-risky", function() atCrash = readFile(mine.file) end)
clean()
writeFile(slotFile(1), (atCrash:gsub("beat %d+", "beat " .. (os.time() - 120))))
launch(0x1100, 0x2100)                        -- the next launch: a new process
local crashed = S.init()
check("detects what crashed", crashed == "pretend-risky", tostring(crashed))
check("blocks it afterwards", S.isBlocked("pretend-risky"))
local ran2 = S.guard("pretend-risky", function() error("should never run") end)
check("blocked operation does not run", ran2 == false)
S.reset()
check("reset clears the block", not S.isBlocked("pretend-risky"))

-- THE 1.7.0 INCIDENT. The host is copy 1, still running and writing its record
-- every tick; the guest was copy 2 and died dressing the host's pawn, with
-- the HUD stand-in on probation. The guest is started again.
clean()
local hostToken = ("%x-%x"):format(0x9000, 0x9100)
writeFile(slotFile(1), record({ token = hostToken, beat = os.time(), phase = "Spawn.tickHost",
                                guards = { "sending a message to the other player" } }))
writeFile(slotFile(2), record({ token = ("%x-%x"):format(0x3000, 0x3100), phase = "Bodies.tick",
                                probation = STANDIN, probationPhases = { "Hud.tick" },
                                guards = { BODIES } }))
launch(0x3200, 0x3300)
local m = #H.log
crashed = S.init()
S.report()
check("the restarted guest finds its own record, not the running host's", S._state().slot == 2,
      tostring(S._state().slot))
check("and blames what was in flight: the body, not the HUD stand-in",
      crashed == BODIES and S.isBlocked(BODIES) and not S.isBlocked(STANDIN), tostring(crashed))
check("says so", since(m, "The game crashed last time during") and since(m, BODIES), "not reported")
check("the running host's record is left alone", readFile(slotFile(1)):find(hostToken, 1, true) ~= nil,
      readFile(slotFile(1)))

-- With no guard in flight, a crash in another module's tick is not the
-- probation feature's.
clean()
writeFile(slotFile(1), record({ token = "aa-bb", phase = "Bodies.tick",
                                probation = STANDIN, probationPhases = { "Hud.tick" } }))
launch(0x4000, 0x4100)
m = #H.log
crashed = S.init()
S.report()
check("a crash in Bodies.tick with nothing in flight does not blame the stand-in on probation",
      crashed == nil and not S.isBlocked(STANDIN) and S.lastCrashPhase() == "Bodies.tick",
      tostring(crashed))
check("it reports the phase and switches nothing off",
      since(m, "running: Bodies.tick") and since(m, "nothing has"), "not reported")

clean()
writeFile(slotFile(1), record({ token = "aa-bb", phase = S.IDLE,
                                probation = STANDIN, probationPhases = { "Hud.tick" } }))
launch(0x4200, 0x4300)
S.init()
S.settle(nil)
check("between ticks, the feature on probation is the one blamed",
      S._state().crashedOn == STANDIN and S.isBlocked(STANDIN), "not blamed")

clean()
writeFile(slotFile(1), record({ token = "aa-bb", phase = "Hud.tick",
                                probation = STANDIN, probationPhases = { "Hud.tick" } }))
launch(0x4400, 0x4500)
S.init()
S.settle(nil)
check("and in the phase its own code runs in", S._state().crashedOn == STANDIN, "not blamed")

clean()
writeFile(slotFile(1), record({ token = "aa-bb", phase = S.IDLE }))
launch(0x4600, 0x4700)
check("a run that stopped between ticks with nothing in flight blames nothing (a clean exit)",
      S.init() == nil and S.lastCrashPhase() == nil and #S.blockedList() == 0, "blamed something")

-- A UE4SS hot reload: same process, new Lua state, a fresh record of its own.
clean()
local sameProcess = launch(0x5000, 0x5100)
writeFile(slotFile(1), record({ token = sameProcess, beat = os.time(), phase = "Bodies.tick",
                                probation = STANDIN, guards = { BODIES } }))
m = #H.log
crashed = S.init()
S.report()
check("a hot reload is not a crash", crashed == nil and not S.isBlocked(BODIES) and not S.isBlocked(STANDIN)
      and S._state().reloaded and S._state().slot == 1, tostring(crashed))
check("and says so", since(m, "hot reload"), "not logged")

-- An earlier build's files, after an update.
clean()
writeFile("RewindTogether-inprogress.txt", "pretend-risky\n")
writeFile("RewindTogether-probation.txt", STANDIN .. "\n")
launch(0x6000, 0x6100)
crashed = S.init()
check("an earlier build's breadcrumb is honoured once", crashed == "pretend-risky", tostring(crashed))
check("its probation file alone blames nothing, and both are gone",
      not S.isBlocked(STANDIN) and readFile("RewindTogether-inprogress.txt") == nil
      and readFile("RewindTogether-probation.txt") == nil, "left behind or blamed")

-- A crash or not. A closed window, Steam's Stop and a killed process leave
-- the same record as a crash; the witnesses are a "closed" line (written as
-- the Lua state closes in order) and the crash report the engine writes
-- before a crashing process dies (native.lua, Native.crashesSince).
local asked = nil
local function reports(n)
    return function(since, forPid) asked = { since = since, pid = forPid } return n end
end
local function lastRun(t)
    clean()
    writeFile(slotFile(1), record(t))
    return launch(0x7000, 0x7100)
end
local function closedRecord(t)
    local text = record(t):gsub("end\n$", "closed its Lua state was closed\nend\n")
    return text
end

lastRun({ token = "aa-bb", phase = S.IDLE, probation = STANDIN, probationPhases = { "Hud.tick" } })
writeFile(slotFile(1), closedRecord({ token = "aa-bb", phase = S.IDLE, probation = STANDIN }))
S.init()
S.settle(nil)
check("a run whose Lua state closed in order is not a crash, even with a feature on probation",
      not S.isBlocked(STANDIN) and S._state().cleanLast ~= nil, tostring(S._state().crashedOn))

lastRun({})
writeFile(slotFile(1), closedRecord({ token = "aa-bb", phase = S.IDLE, probation = STANDIN }))
S.init()
S.settle(reports(1))
check("unless the engine wrote a crash report after it (a crash during shutdown)",
      S.isBlocked(STANDIN), "not blamed")

lastRun({})
writeFile(slotFile(1), record({ token = "aa-bb", phase = S.IDLE, probation = STANDIN,
                                beat = 1700000000 }):gsub("token aa%-bb\n", "token aa-bb\npid 4242\n"))
S.init()
local m2 = #H.log
S.settle(reports(0))
S.report()
check("a window closed while a feature is on probation (no crash report): nothing switched off",
      not S.isBlocked(STANDIN) and since(m2, "stopped without crashing"), "blamed")
check("the engine is asked about that process, from just before its last write",
      asked ~= nil and asked.pid == 4242 and asked.since == 1700000000 - 5, asked and
      ("since %s, pid %s"):format(tostring(asked.since), tostring(asked.pid)) or "never asked")

lastRun({ token = "aa-bb", phase = S.IDLE, probation = STANDIN })
S.init()
S.settle(reports(1))
check("with a crash report, the feature on probation is blamed", S.isBlocked(STANDIN), "not blamed")

lastRun({ token = "aa-bb", phase = S.IDLE, probation = STANDIN })
S.init()
S.settle(function() return nil end)
check("when nobody can tell, it is blamed as before", S.isBlocked(STANDIN), "not blamed")

lastRun({ token = "aa-bb", phase = "Bodies.tick" })
S.init()
S.settle(reports(0))
check("a killed copy mid-tick (no crash report) is not reported as a crash",
      S.lastCrashPhase() == nil, tostring(S.lastCrashPhase()))

lastRun({ token = "aa-bb", phase = "Bodies.tick", guards = { BODIES } })
S.init()
S.settle(reports(0))
check("an operation left in flight is blamed whatever else is known",
      S.isBlocked(BODIES), "not blamed")

-- Every run that ended is judged, not only the one whose slot is taken.
clean()
writeFile(slotFile(1), record({ token = "aa-bb", guards = { "op of run one" } }))
writeFile(slotFile(3), record({ token = "cc-dd", guards = { "op of run two" } }))
launch(0x7200, 0x7300)
S.init()
check("two runs that ended are both judged", S.isBlocked("op of run one") and S.isBlocked("op of run two"),
      "only one was")
check("and the record not taken over is cleared", readFile(slotFile(3)) == nil and S._state().slot == 1,
      tostring(S._state().slot))

-- A record still being written: a running copy - or one killed seconds ago
-- and started straight again (measured: 7 s, inside the 10 s window).
local function freshForeign(alive)
    clean()
    writeFile(slotFile(1), record({ token = "ee-ff", beat = os.time(), phase = S.IDLE,
                                    probation = STANDIN }):gsub("token ee%-ff\n", "token ee-ff\npid 5150\n"))
    launch(0x7400, 0x7500)
    S.init()
    S.settle(reports(1), function(p) if p == 5150 then return alive end return nil end)
    return readFile(slotFile(1))
end
local left = freshForeign(true)
check("a fresh record of a copy that is running is left alone",
      not S.isBlocked(STANDIN) and left ~= nil and S._state().slot == 2, tostring(S._state().slot))
left = freshForeign(false)
check("one whose process is gone is judged after all (and cleared)",
      S.isBlocked(STANDIN) and left == nil, left)
left = freshForeign(nil)
check("and when nobody can say, it is left for later", not S.isBlocked(STANDIN) and left ~= nil, "judged")

-- This run's own side: the pid goes in, and so does "closed" as the Lua
-- state closes - from this init's finalizer only, never an earlier one's.
lastRun({})
S.init()
S.setPid(4242)
local liveFile = S._state().file
check("the record names this process once RewindNative says which it is",
      (readFile(liveFile) or ""):find("\npid 4242\n", 1, true) ~= nil, readFile(liveFile))
S._close()
check("closing the Lua state marks the record closed",
      (readFile(liveFile) or ""):find("\nclosed its Lua state was closed\n", 1, true) ~= nil, readFile(liveFile))
S._forget()
os.remove(liveFile)
S.init()
local newer = S._state().file
S._forget()
S._close()                                   -- the finalizer of an init that is over
check("a finalizer from an earlier init writes nothing", not (readFile(newer) or ""):find("closed", 1, true),
      readFile(newer))

local mainSrc7 = io.open(SCRIPTS .. "/main.lua", "r"):read("a")
local repairAt7 = mainSrc7:find("Native.repairNameCache()", 1, true)
local settleAt = mainSrc7:find("Safety.settle(Native.crashesSince, Native.pidAlive)", 1, true)
local reportAt = mainSrc7:find("Safety.report()", 1, true)
check("main.lua settles the last run once RewindNative is up, before reporting",
      repairAt7 and settleAt and reportAt and repairAt7 < settleAt and settleAt < reportAt,
      "not called, or out of order")

-- Put things back for the sections below: a fresh record, no token.
clean()
H.staticObjects["/Script/CoreUObject.Default__Object"] = nil
if gsCdo then gsCdo.GetAddress = gsAddress end
S.init()
end

-- ----------------------------------- 7b. UE4SS's member-name cache --
-- Measured in the guest's crash dump: UE4SS remembers member names by
-- pointers into Lua strings, and a hot reload frees them (RewindNative.cpp,
-- "THE UE4SS NAME CACHE"; its native test reproduces the crash).

print("\n-- UE4SS's member-name cache --")
do
local Native = require("native")
local purges, reply = 0, 37
local base = {
    rt_version = function() return 3, "RewindNative (fake)" end,
    rt_hook_return = function() return 0xD8 end, rt_redirect_begin = function() return 0 end,
    rt_redirect_end = function() return 0 end, rt_unhook_all = function() return 0 end,
    rt_stats = function() return 0, 0xD8, 0, 0 end, rt_read_ptr = function() return nil end,
}
local function withCache()
    local e = {}
    for k, v in pairs(base) do e[k] = v end
    e.rt_namecache_purge = function() purges = purges + 1 return reply end
    e.rt_namecache = function() return 1, 12, 1024, 37, purges end
    return e
end
local function since(m, pattern)
    for i = m + 1, #H.log do if H.log[i]:find(pattern, 1, true) then return true end end
    return false
end

Native._fake(withCache())
local m = #H.log
local dropped = Native.repairNameCache()
check("the mod empties UE4SS's name cache and says how many names went",
      dropped == 37 and purges == 1 and since(m, "member-name cache emptied (37"), tostring(dropped))
check("rt.native shows it", table.concat(Native.status(), "\n"):find("UE4SS name cache: 12 name(s), 1024 buckets", 1, true) ~= nil,
      table.concat(Native.status(), " | "))
reply = -1
local none, why = Native.repairNameCache()
check("on a UE4SS without that cache it does nothing and says why", none == nil and why:find("no such cache", 1, true) ~= nil,
      tostring(why))
reply = -2
m = #H.log
local left, why2 = Native.repairNameCache()
check("one that does not look right is left alone, loudly", left == nil and since(m, "left alone"), tostring(why2))
reply = 5
purges = 0
getmetatable(Native._onClose).__gc()
check("as the Lua state closes (a hot reload) it is emptied again", purges == 1, ("%d purge(s)"):format(purges))

local withReports = withCache()
withReports.rt_crashes_since = function(since, p) return (since == 100 and p == 7) and 2 or -1, 0 end
withReports.rt_pid = function() return 7 end
Native._fake(withReports)
check("crash reports are counted through RewindNative, for this process",
      Native.crashesSince(100, 7) == 2 and Native.pid() == 7, tostring(Native.crashesSince(100, 7)))
check("a Crashes folder that cannot be read is 'cannot tell', not 'no crash'",
      Native.crashesSince(5, 7) == nil, tostring(Native.crashesSince(5, 7)))

Native._fake(base)
check("without those exports nobody can tell", Native.crashesSince(100, 7) == nil and Native.pid() == nil,
      "answered anyway")
local old, why3 = Native.repairNameCache()
check("an older RewindNative.dll says so", old == nil and why3:find("older than the mod", 1, true) ~= nil, tostring(why3))
Native._fake(nil)

local mainSrc = io.open(SCRIPTS .. "/main.lua", "r"):read("a")
local repairAt = mainSrc:find("Native.repairNameCache()", 1, true)
local firstInit = mainSrc:find("Net.init(Config)", 1, true)
check("main.lua repairs it before any module touches the engine",
      repairAt ~= nil and firstInit ~= nil and repairAt < firstInit, "not called, or called too late")

-- A name built at run time must outlive the call that used it.
local UEm = require("ue")
local dyn = "Dyn" .. "amic" .. "Member" .. tostring(os.time())
UEm.TryGet(H.obj("Thing", { __isActor = false }), dyn)
check("a member name built at run time is pinned when it is used", UEm._isPinned(dyn), dyn)
end

-- ------------------------------------------------------------- 8. commands --

-- ------------------------------------------ 8. the launcher's handoff --

print("\n-- launcher handoff (launch.json / status.json) --")
local Launch = require("launchfile")
local NetM   = require("net")

local parsed = Launch._parseFlat('{ "action": "join", "address": "127.0.0.1:27016", ' ..
                                 '"host_name": "Al \\"Rewind\\"", "written": 1760467200, "x": true }')
check("reads the launcher's JSON", parsed and parsed.action == "join"
      and parsed.address == "127.0.0.1:27016" and parsed.written == 1760467200
      and parsed.host_name == 'Al "Rewind"' and parsed.x == true,
      parsed and tostring(parsed.host_name) or "<nil>")
check("refuses what is not one flat object", Launch._parseFlat("[1,2]") == nil)

-- Standalone, at the main menu: a controller, no pawn, no session.
local savedDriver = H.theWorld.NetDriver
H.theWorld.NetDriver = nil
UE.beginFrame()

local joined = nil
local realJoin = NetM.join
NetM.join = function(addr) joined = addr return true end

local function writeReq(text)
    local fh = io.open("RewindTogether.launch.json", "w")
    fh:write(text)
    fh:close()
end

writeReq(('{ "action": "join", "address": "127.0.0.1:27016", "written": %d }'):format(os.time()))
Launch.tick(5000.0, 27015)
check("a launcher join happens from the main menu", joined == "127.0.0.1:27016",
      "joined " .. tostring(joined))
check("the request is used up", io.open("RewindTogether.launch.json", "r") == nil,
      "launch.json is still there - it would fire again next launch")

joined = nil
writeReq(('{ "action": "join", "address": "10.0.0.9", "written": %d }'):format(os.time() - 3600))
Launch.tick(5002.0, 27015)
check("an hour-old request is ignored", joined == nil, "joined " .. tostring(joined))

local st = io.open("RewindTogether.status.json", "r")
local stText = st and st:read("a") or ""
if st then st:close() end
local stParsed = Launch._parseFlat(stText)
check("writes a heartbeat the launcher can read", stParsed and stParsed.version == NetM.VERSION
      and type(stParsed.updated) == "number", stText ~= "" and stText or "<no status.json>")

-- Steam's own Join Game for a launcher-hosted session reaches the GAME as
-- "+rt_join <id>". That string comes from a friend's rich presence and is
-- about to be part of a command line, so it is validated hard.
local ran = {}
local realExecute = os.execute
os.execute = function(cmd) ran[#ran + 1] = cmd return true end

check("a malformed Steam ID never reaches a command line",
      Launch.askLauncherToJoin('7656119" & calc & "') == false and #ran == 0,
      ran[1] or "<nothing ran>")
os.remove("RewindTogether.launcher.txt")
check("without the launcher installed it says so instead of running anything",
      Launch.askLauncherToJoin("76561198000000102") == false and #ran == 0,
      ran[1] or "<nothing ran>")

local fakeExe = "fake-launcher-for-test.exe"
local fe = io.open(fakeExe, "wb") fe:write("x") fe:close()
local lt = io.open("RewindTogether.launcher.txt", "w") lt:write(fakeExe .. "\n") lt:close()
check("with the launcher installed it is started with --join",
      Launch.askLauncherToJoin("76561198000000102") == true and #ran == 1
      and ran[1]:find("--join 76561198000000102", 1, true) ~= nil,
      ran[1] or "<nothing ran>")
os.remove(fakeExe)
os.remove("RewindTogether.launcher.txt")
os.execute = realExecute

-- HOST with a save slot: loaded from the main menu exactly as the game's own
-- menu does it (decompiled UX_Boot_StartOption), no clicks.
local savedGm, savedGmBase = H.world.objects["Core_Gamemode_C"], H.world.objects["GameModeBase"]
H.world.objects["Core_Gamemode_C"] = nil
H.world.objects["GameModeBase"] = { H.obj("MainMenu_GameMode_C", {}) }
local gi = H.spawn("Core_GameInstance_C", { ["Save Slot"] = "" })
local opened = nil
local gsStub = H.staticObjects["/Script/Engine.Default__GameplayStatics"]
local realOpen = gsStub and gsStub.OpenLevel
if gsStub then gsStub.OpenLevel = function(_, w, name, abs, opts) opened = name and name.ToString and name:ToString() end end
UE.beginFrame()
writeReq(('{ "action": "host", "slot": "Player_Save2", "written": %d }'):format(os.time()))
Launch.tick(5004.0, 27015)
Launch.tick(5006.0, 27015)
check("a launcher HOST with a slot loads that save from the menu",
      gi["Save Slot"] == "Player_Save2" and opened == "L_Player_Store_01",
      ("slot %s, opened %s"):format(tostring(gi["Save Slot"]), tostring(opened)))

gi["Save Slot"] = ""
opened = nil
writeReq(('{ "action": "host", "slot": "../evil", "written": %d }'):format(os.time()))
Launch.tick(5010.0, 27015)
Launch.tick(5012.0, 27015)
check("a slot name the game does not have is refused", gi["Save Slot"] == "" and opened == nil,
      ("slot %s, opened %s"):format(tostring(gi["Save Slot"]), tostring(opened)))
if gsStub then gsStub.OpenLevel = realOpen end
H.world.objects["Core_Gamemode_C"], H.world.objects["GameModeBase"] = savedGm, savedGmBase
for i, o in ipairs(H.world.objects["Core_GameInstance_C"] or {}) do
    if o == gi then table.remove(H.world.objects["Core_GameInstance_C"], i) break end
end
UE.beginFrame()

NetM.join = realJoin
H.theWorld.NetDriver = savedDriver
UE.beginFrame()
os.remove("RewindTogether.status.json")

-- ------------------------------------------------ 9. keys, polled --

print("\n-- keys, read on the game thread --")
local pressed = { F6 = true }
local keyPC = H.spawn("PlayerController", {
    Player = H.obj("LocalPlayer", { __isActor = false }),
    IsLocalController = function() return true end,
    GetWorld = function() return H.theWorld end,
    IsInputKeyDown = function(_, key)
        local n = key and key.KeyName and key.KeyName:ToString()
        return pressed[n] == true
    end,
})
UE.beginFrame()
pcall(H.tick)                 -- the tick resolves the controller the poll reuses
-- Whichever local controller the tick settled on is the one the poll asks.
local resolved = UE.peekPlayerController()
check("the poll reuses the tick's controller", resolved ~= nil, "nothing resolved")
if resolved then resolved.IsInputKeyDown = keyPC.IsInputKeyDown end
local before = #H.log
H.poll()
local fired = 0
for i = before + 1, #H.log do if H.log[i]:find("---- Rewind Together", 1, true) then fired = fired + 1 end end
check("a held key fires its action", fired == 1, ("F6 fired %d time(s)"):format(fired))
before = #H.log
H.poll()
H.poll()
fired = 0
for i = before + 1, #H.log do if H.log[i]:find("---- Rewind Together", 1, true) then fired = fired + 1 end end
check("holding it does not repeat", fired == 0, ("fired again %d time(s)"):format(fired))
pressed.F6 = nil
for i, o in ipairs(H.world.objects["PlayerController"] or {}) do
    if o == keyPC then table.remove(H.world.objects["PlayerController"], i) break end
end
UE.beginFrame()

print("\n-- every console command runs without throwing --")
for name, fn in pairs(H.commands) do
    local okc, errc = pcall(fn, name, {}, nil)
    check(name, okc, errc)
end

-- ------------------------------------- 10. finding things without walking --

print("\n-- finding things: the engine's route --")
-- MEASURED in 1.7.0: FindAllOf and FindFirstOf cost 15-17 ms a call whatever
-- they look for, and the mod made about 40 a second - 60% of the host's game
-- thread. Everything above ran without the engine's route (the fallbacks);
-- here it is switched on, and every walk is counted.
UE._resetLookups()

local walks = {}
local realAll, realFirst = _G.FindAllOf, _G.FindFirstOf
_G.FindAllOf = function(n) walks[#walks + 1] = n return realAll(n) end
_G.FindFirstOf = function(n) walks[#walks + 1] = n return realFirst(n) end
local function walked() local n = #walks walks = {} return n end

-- Classes with a real chain, the one measured on the game:
-- videotape_C > Cartridge_Base_C > PickupActor_C > Actor.
local classByPath = {}
local function fakeClass(kind, path, super)
    local name = path:match("([^%.]+)$")
    local c = { __cdo = {} }
    c.IsValid        = function() return true end
    c.GetFName       = function() return FName(name) end
    c.GetFullName    = function() return kind .. " " .. path end
    c.GetSuperStruct = function() return super end
    c.GetCDO         = function() return c.__cdo end
    c.__cdo.IsValid  = function() return true end
    classByPath[path] = c
    return c
end
local actorCls  = fakeClass("Class", "/Script/Engine.Actor", nil)
local pcCls     = fakeClass("Class", "/Script/Engine.PlayerController", actorCls)
local pickupCls = fakeClass("BlueprintGeneratedClass", "/Game/VideoStore/core/blueprint/PickupActor.PickupActor_C", actorCls)
local cartCls   = fakeClass("BlueprintGeneratedClass", "/Game/VideoStore/asset/prop/vhs/Cartridge_Base.Cartridge_Base_C", pickupCls)
local tapeCls   = fakeClass("BlueprintGeneratedClass", "/Game/VideoStore/asset/prop/vhs/videotape.videotape_C", cartCls)
local panelCls  = fakeClass("WidgetBlueprintGeneratedClass", "/Game/UI/Panel_C.Panel_C", nil)

local function chainHas(cls, want)
    local c = cls
    while c do
        if c == want then return true end
        c = c.GetSuperStruct and c.GetSuperStruct() or nil
    end
    return false
end
local function alive(o)
    return o.IsValid(o) and o.__destroying ~= true and o.__garbage ~= true
end

local actorQueries = 0
local NULL_OBJECT = { IsValid = function() return false end }   -- what the engine hands back
local gsObj = H.staticObjects["/Script/Engine.Default__GameplayStatics"]
local savedGs = {}
local gsFns = {
    GetNumPlayerControllers = function()
        local n = 0
        for _, pc in ipairs(H.world.objects["PlayerController"] or {}) do
            if alive(pc) then n = n + 1 end
        end
        return n
    end,
    GetPlayerController = function(_, _, index)
        local i = -1
        for _, pc in ipairs(H.world.objects["PlayerController"] or {}) do
            if alive(pc) then
                i = i + 1
                if i == index then return pc end
            end
        end
        return NULL_OBJECT
    end,
    GetGameMode  = function() return NULL_OBJECT end,
    GetGameState = function() return NULL_OBJECT end,
    -- MEASURED: the out-table is filled with RemoteUnrealParam references,
    -- not actors, and UE4SS keeps a registry reference to it forever.
    GetAllActorsOfClass = function(_, _, cls, out)
        local reg = debug.getregistry()
        reg[#reg + 1] = out
        actorQueries = actorQueries + 1
        for _, list in pairs(H.world.objects) do
            for _, o in ipairs(list) do
                if o.GetClass and alive(o) and chainHas(o:GetClass(), cls) then
                    out[#out + 1] = { type = function() return "RemoteUnrealParam" end,
                                      get = function() return o end }
                end
            end
        end
    end,
    GetActorOfClass = function(_, _, cls)
        actorQueries = actorQueries + 1
        for _, list in pairs(H.world.objects) do
            for _, o in ipairs(list) do
                if o.GetClass and alive(o) and chainHas(o:GetClass(), cls) then return o end
            end
        end
        return NULL_OBJECT
    end,
}
for k, fn in pairs(gsFns) do savedGs[k] = gsObj[k] gsObj[k] = fn end
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = H.obj("KismetSystemLibrary", {
    __isActor = false,
    MakeSoftObjectPath = function(_, p) return { path = p } end,
    Conv_SoftObjPathToSoftObjRef = function(_, sp) return sp end,
    Conv_SoftObjectReferenceToObject = function(_, ref)
        return classByPath[ref.path] or H.byName[ref.path] or NULL_OBJECT
    end,
})
local world = H.obj("World", { __isActor = false, NetDriver = H.theWorld.NetDriver })
local worldAddress = 1000
world.GetAddress = function() return worldAddress end
local gi = H.obj("Core_GameInstance_C", { __isActor = false, GetWorld = function() return world end })
H.world.objects["GameInstance"] = { gi }

local function tape(fields)
    local o = H.spawn("videotape_C", fields or {})
    o.GetClass = function() return tapeCls end
    return o
end
local tapes = { tape(), tape(), tape() }

UE.beginFrame()
UE.GetGameInstance()                       -- the one walk on purpose: once per process
walked()
local found = UE.findAll("Cartridge_Base_C") or {}
check("subclasses are found through the engine, without a walk",
      #found == 3 and walked() == 0, ("%d found, %d walk(s)"):format(#found, #walks))
local q = actorQueries
UE.findAll("Cartridge_Base_C")
check("asking again in the same tick is free", actorQueries == q,
      ("%d more engine queries"):format(actorQueries - q))
UE.endFrame()
UE.beginFrame()
UE.findAll("Cartridge_Base_C")
check("a new tick asks the engine again", actorQueries == q + 1, "the list was kept across ticks")
local function registrySize()
    local n = 0
    for _ in pairs(debug.getregistry()) do n = n + 1 end
    return n
end
local regBefore = registrySize()
for _ = 1, 5 do
    UE.endFrame() UE.beginFrame()
    UE.findAll("Cartridge_Base_C")
end
check("the registry reference UE4SS keeps to each actor list is released",
      registrySize() == regBefore, ("%d entries more after 5 lists"):format(registrySize() - regBefore))
check("the first one is one engine call, no walk",
      UE.findFirst("Cartridge_Base_C") ~= nil and walked() == 0, ("%d walk(s)"):format(#walks))

UE.findAll("Nope_C")
local first = walked()
UE.endFrame() UE.beginFrame()
UE.findAll("Nope_C")
UE.endFrame() UE.beginFrame()
UE.findAll("Nope_C")
check("a class that does not exist is walked for once, then backed off",
      first == 1 and walked() == 0, ("%d, then %d walk(s)"):format(first, #walks))
worldAddress = 2000
UE.endFrame() UE.beginFrame()
UE.findAll("Nope_C")
check("a new world looks for it again", walked() == 1, ("%d walk(s)"):format(#walks))

local panel = H.spawn("Panel_C", { __isActor = false })
panel.GetClass = function() return panelCls end
UE.findAll("Panel_C") UE.findAll("Panel_C")
check("a non-actor class still walks, once per tick", walked() == 2,     -- learn + list
      ("%d walk(s)"):format(#walks))
H.world.objects["Panel_C"] = nil

-- Controllers come from the engine's own list.
local savedPcs = H.world.objects["PlayerController"]
H.world.objects["PlayerController"] = {}
local hostSide = H.spawn("PlayerController", {
    Player = H.obj("LocalPlayer", { __isActor = false }), Pawn = nil,
    IsLocalController = function() return false end,
    GetWorld = function() return world end,
})
local mine = H.spawn("PlayerController", {
    Player = H.obj("LocalPlayer", { __isActor = false }),
    IsLocalController = function() return true end,
    GetWorld = function() return world end,
})
UE.endFrame() UE.beginFrame()
walked()
check("the local controller comes from the engine's list",
      UE.sameObject(UE.GetPlayerController(), mine) and walked() == 0,
      ("%d walk(s)"):format(#walks))
check("so does every controller", #UE.GetAllPlayerControllers() >= 2 and walked() == 0,
      ("%d walk(s)"):format(#walks))
UE.endFrame()
check("the key poll, between ticks, asks fresh and never walks",
      UE.sameObject(UE.peekPlayerController(), mine) and walked() == 0,
      ("%d walk(s)"):format(#walks))
H.world.objects["PlayerController"] = savedPcs

-- Single player: the world has no net driver, and that is the answer.
local savedDriver = world.NetDriver
world.NetDriver = nil
UE.beginFrame()
check("single player is known without a walk", UE.GetNetMode() == 0 and walked() == 0,
      ("%d walk(s)"):format(#walks))
world.NetDriver = savedDriver

print("\n-- replication: every actor checked, not just class defaults --")
-- MEASURED in 1.7.0: a tape spawned after its class default was patched came
-- out without bReplicateMovement, and with the default patched, guests were
-- never sent the flag at all (395 of 396 tapes on a guest had it off).
local Rep = require("replication")
local repCfg = { ReplicatedClasses = { "Cartridge_Base" }, PropNetUpdateFrequency = 10,
                 PawnNetUpdateFrequency = 30 }
Rep.init(repCfg)
Rep.setActive(true)
local setRep = 0
local fresh = tape({ bReplicates = true, bReplicateMovement = false,
    GetLocalRole = function() return 3 end,
    SetReplicates = function(self, v) self.bReplicates = v setRep = setRep + 1 end,
    SetReplicateMovement = function(self, v) self.bReplicateMovement = v end,
    FlushNetDormancy = function() end,
})
H.theWorld.NetDriver.ServerConnection = nil
UE.endFrame() UE.beginFrame()
Rep.sweep()
-- It replicates already: SetReplicates is not called again (on UE 5 it would
-- reset the actor's RemoteRole - see the pawn check below).
check("the host patches an actor its class default did not reach",
      fresh.bReplicateMovement == true and setRep == 0, ("%s, %d SetReplicates"):format(tostring(fresh.bReplicateMovement), setRep))
check("bReplicateMovement never goes on a class default, so guests are sent it",
      tapeCls.__cdo.bReplicates == true and tapeCls.__cdo.bReplicateMovement == nil,
      tostring(tapeCls.__cdo.bReplicateMovement))
UE.endFrame() UE.beginFrame()
Rep.sweep()
check("a patched actor is left alone after that", setRep == 0, ("%d patches"):format(setRep))
do
-- MEASURED: a furniture box spawned in build mode carried bReplicates = true
-- and never reached the guest. SetReplicates only registers an actor with
-- the net driver when it sees the flag go from false to true, and the sweep
-- used to write the flag itself first.
local sawOff = nil
tape({ bReplicates = false, bReplicateMovement = false,
    GetLocalRole = function() return 3 end,
    SetReplicates = function(self, v)
        if sawOff == nil then sawOff = (self.bReplicates == false) end
        self.bReplicates = v
    end,
    SetReplicateMovement = function(self, v) self.bReplicateMovement = v end,
    FlushNetDormancy = function() end,
})
UE.endFrame() UE.beginFrame()
Rep.sweep()
check("SetReplicates runs while the flag is still off, so the actor is registered",
      sawOff == true, "SetReplicates saw " .. tostring(sawOff))
end
do
-- MEASURED: a guest's own pawn, once patched, was a SimulatedProxy on the
-- guest (SetReplicates(true) resets RemoteRole on UE 5): it could not walk,
-- and the host's copy never moved. And with the server not correcting the
-- guest but not taking their position either, any drift stayed.
Rep.init({ ReplicatedClasses = { "Player_Character" }, PropNetUpdateFrequency = 10, PawnNetUpdateFrequency = 30 })
local guestCtrl = H.obj("PlayerController", { __isActor = false,
    IsPlayerController = function() return true end, IsLocalController = function() return false end })
local setReps = 0
local move = H.obj("CharacterMovementComponent", { __isActor = false,
    bIgnoreClientMovementErrorChecksAndCorrection = false, bServerAcceptClientAuthoritativePosition = false })
local guestPawn = H.spawn("Player_Character_C", { bReplicates = true, bReplicateMovement = true,
    RemoteRole = 1, Controller = guestCtrl, CharacterMovement = move,
    GetLocalRole = function() return 3 end,
    SetReplicates = function(self, v) setReps = setReps + 1 self.RemoteRole = 1 end,
    SetReplicateMovement = function(self, v) self.bReplicateMovement = v end,
    FlushNetDormancy = function() end, ForceNetUpdate = function() end })
UE._resetLookups()
UE.endFrame() UE.beginFrame()
Rep.sweep()
check("a guest's pawn is not passed through SetReplicates again, and a demoted one is theirs to move again",
      setReps == 0 and guestPawn.RemoteRole == 2, ("%d SetReplicates, RemoteRole %s"):format(setReps, tostring(guestPawn.RemoteRole)))
check("and the host takes the guest's position as well as not correcting it",
      move.bIgnoreClientMovementErrorChecksAndCorrection == true and move.bServerAcceptClientAuthoritativePosition == true,
      ("ignore %s, accept %s"):format(tostring(move.bIgnoreClientMovementErrorChecksAndCorrection),
                                      tostring(move.bServerAcceptClientAuthoritativePosition)))
-- The host moves the guest (a placement): for a moment the engine checks
-- the guest again, so the guest is told; then trust returns.
Rep.beforeHostMovesGuest(guestPawn)
UE.endFrame() UE.beginFrame()
Rep.sweep()
check("a move the host makes to a guest's pawn is checked, so the guest is told of it",
      move.bIgnoreClientMovementErrorChecksAndCorrection == false and move.bServerAcceptClientAuthoritativePosition == false,
      ("ignore %s, accept %s"):format(tostring(move.bIgnoreClientMovementErrorChecksAndCorrection),
                                      tostring(move.bServerAcceptClientAuthoritativePosition)))
Rep.restoreTrust(os.clock() + 10)
check("and the guest's position is trusted again afterwards",
      move.bIgnoreClientMovementErrorChecksAndCorrection == true and move.bServerAcceptClientAuthoritativePosition == true,
      ("ignore %s, accept %s"):format(tostring(move.bIgnoreClientMovementErrorChecksAndCorrection),
                                      tostring(move.bServerAcceptClientAuthoritativePosition)))
for i, o in ipairs(H.world.objects["Player_Character_C"] or {}) do
    if o == guestPawn then table.remove(H.world.objects["Player_Character_C"], i) break end
end
Rep.init(repCfg)
UE._resetLookups()
end
do
-- MEASURED: the snack display's boxes are child actors, built by their shelf
-- on every machine; replicating the host's gave guests a second set, with
-- collision where the host had none, and customers climbed it on the guest.
local parent = H.obj("SnackShelf_C", {})
local turnedOff, patchedChild = 0, 0
local child = tape({ bReplicates = true, bReplicateMovement = false,
    GetParentActor = function() return parent end,
    GetLocalRole = function() return 3 end,
    SetReplicates = function(self, v) self.bReplicates = v if v == false then turnedOff = turnedOff + 1 end end,
    SetReplicateMovement = function(self, v) self.bReplicateMovement = v patchedChild = patchedChild + 1 end,
    FlushNetDormancy = function() end,
})
UE.endFrame() UE.beginFrame()
Rep.sweep()
check("a child actor is not replicated - every machine builds its own - and is switched off if it was",
      turnedOff == 1 and child.bReplicates == false and patchedChild == 0,
      ("switched off %d, patched %d"):format(turnedOff, patchedChild))
for i, o in ipairs(H.world.objects["videotape_C"] or {}) do
    if o == child then table.remove(H.world.objects["videotape_C"], i) break end
end
end


-- The guest's own check.
local onRep = {}
local function guestTape(loc, attached)
    local t = tape({ bReplicateMovement = false,
        ReplicatedMovement = { Location = loc },
        GetAttachParentActor = function() return attached end,
        OnRep_ReplicatedMovement = function(self) onRep[#onRep + 1] = self end,
    })
    return t
end
for _, t in ipairs(H.world.objects["videotape_C"]) do t.bReplicateMovement = true end
local stale    = guestTape({ X = 1966, Y = -1190, Z = 139 })
local never    = guestTape({ X = 0, Y = 0, Z = 0 })
local inHand   = guestTape({ X = 5, Y = 5, Z = 5 }, H.obj("Player_Character_C", {}))
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
Rep._resetGuestState()
UE.endFrame() UE.beginFrame()
local fixedNow = Rep.patchGuestMovement()
check("a guest turns the flag on where it is off",
      fixedNow == 3 and stale.bReplicateMovement and never.bReplicateMovement
      and inHand.bReplicateMovement, ("%d fixed"):format(fixedNow))
check("and applies the position it dropped - only where one was sent and nothing holds it",
      #onRep == 1 and onRep[1] == stale, ("%d re-applied"):format(#onRep))
H.theWorld.NetDriver.ServerConnection = nil

-- Put everything back the way the earlier sections expect it.
Rep.setActive(false)
Rep.init(require("config"))
H.world.objects["videotape_C"] = nil
H.world.objects["GameInstance"] = nil
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = nil
for k in pairs(gsFns) do gsObj[k] = savedGs[k] end
_G.FindAllOf, _G.FindFirstOf = realAll, realFirst
UE._resetLookups()
UE.beginFrame()


do
print("\n-- skins: walls and furniture in the host's look --")
-- MEASURED: a guest saw the level's default walls, ceiling, carpet and
-- counter. The numbers were replicated; nothing on a guest applied them.
local SkinSync = require("skinsync")
SkinSync.reset()
local function skinComp(m, s, loaded)
    local c = H.obj("AC_MeshSkin_C", { __isActor = false, calls = {},
        ["Current Mesh Use"] = m, ["Current Skin Use"] = s, ["Savegame data loaded"] = loaded })
    c["Load Asset"] = function(self, force) self.calls[#self.calls + 1] = "Load Asset " .. tostring(force) end
    c["Manual Load Asset"] = function(self) self.calls[#self.calls + 1] = "Manual Load Asset" end
    c["Load Material"] = function(self) self.calls[#self.calls + 1] = "Load Material" end
    return c
end
local function skinned(cls, x, y, z, m, s, loaded)
    return H.spawn(cls, { AC_MeshSkin = skinComp(m, s, loaded),
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end })
end
local savedWalls, savedShelves = H.world.objects["Wall_C"], H.world.objects["Shelve_C"]
H.world.objects["Wall_C"], H.world.objects["Shelve_C"] = {}, {}
local hWall    = skinned("Wall_C",   1980, -1510,     0, 0, 0, true)
local hShelf   = skinned("Shelve_C", 1500, -1800,     0, 2, 3, true)
local hDisplay = skinned("Shelve_C", 1970, -1860,     0, 0, 6, true)
skinned("Shelve_C", 0, 0, -2000, 1, 1, true)                 -- packed in a box: not sent
H.theWorld.NetDriver.ServerConnection = nil
UE.beginFrame()
local sentBefore = #sentStrings
SkinSync.tickHost(1000)
local skinMsgs = {}
for i = sentBefore + 1, #sentStrings do
    if sentStrings[i]:find("RT1|skins", 1, true) then skinMsgs[#skinMsgs + 1] = sentStrings[i] end
end
check("the host sends every skinned object to a guest", #skinMsgs == 1
      and skinMsgs[1]:find("Wall_C;1980;-1510;0;0;0", 1, true) ~= nil
      and skinMsgs[1]:find("Shelve_C;1970;-1860;0;0;6", 1, true) ~= nil,
      skinMsgs[1] or "nothing sent")
check("but nothing packed away below the floor", skinMsgs[1] and skinMsgs[1]:find("-2000", 1, true) == nil,
      skinMsgs[1])

-- The guest: its own copies of the same objects, found by class and place.
H.world.objects["Wall_C"], H.world.objects["Shelve_C"] = {}, {}
local gWall    = skinned("Wall_C",   1980, -1510,     0, 1, 0, false)   -- the level's own value
local gShelf   = skinned("Shelve_C", 1500, -1800,     0, 2, 3, nil)     -- dressed itself at BeginPlay
local gDisplay = skinned("Shelve_C", 1970.004, -1860, 0, 0, 0, nil)     -- replicated wrong
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, skinMsgs[1])
Chan.pump()
SkinSync.tickGuest(2000)
local wc = gWall.AC_MeshSkin
check("a wall gets the host's numbers and loads them the way a save load does",
      wc["Current Mesh Use"] == 0 and wc["Current Skin Use"] == 0
      and wc["Savegame data loaded"] == false and wc.calls[1] == "Load Asset false",
      table.concat(wc.calls, ", "))
check("never Load Asset(true): that path resets the skin to 0",
      (function() for _, c in ipairs(wc.calls) do if c == "Load Asset true" then return false end end return true end)(),
      table.concat(wc.calls, ", "))
check("furniture already in the host's look is left alone", #gShelf.AC_MeshSkin.calls == 0,
      table.concat(gShelf.AC_MeshSkin.calls, ", "))
check("furniture in the wrong skin is dressed again",
      gDisplay.AC_MeshSkin["Current Skin Use"] == 6 and gDisplay.AC_MeshSkin.calls[1] == "Manual Load Asset",
      table.concat(gDisplay.AC_MeshSkin.calls, ", "))

-- Later the host re-skins the shelf (the skin tool): only that goes out, and
-- the guest reloads the materials alone.
H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["Shelve_C"] = { hShelf, hDisplay }
H.world.objects["Wall_C"] = { hWall }
hShelf.AC_MeshSkin["Current Skin Use"] = 4
UE.beginFrame()
sentBefore = #sentStrings
SkinSync.tickHost(1003)
local diff = sentStrings[#sentStrings]
check("a change goes out on its own", #sentStrings == sentBefore + 1 and diff:find("Shelve_C;1500;-1800;0;2;4", 1, true) ~= nil
      and diff:find("Wall_C", 1, true) == nil, tostring(diff))
H.world.objects["Wall_C"], H.world.objects["Shelve_C"] = { gWall }, { gShelf, gDisplay }
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, diff)
Chan.pump()
SkinSync.tickGuest(2010)
check("and the guest reloads only the materials", gShelf.AC_MeshSkin["Current Skin Use"] == 4
      and gShelf.AC_MeshSkin.calls[#gShelf.AC_MeshSkin.calls] == "Load Material",
      table.concat(gShelf.AC_MeshSkin.calls, ", "))
H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["Wall_C"], H.world.objects["Shelve_C"] = savedWalls, savedShelves
SkinSync.reset()
UE.beginFrame()
end

do
print("\n-- a guest's action and the host's HUD --")
-- MEASURED: a guest sold a standee, the store's money went up $10.00, and the
-- host's HUD kept the old total - the widget is hidden from the game for the
-- length of a replay, and Change Money skips the HUD without it.
local GuestInput2 = require("guestinput")
local Native = require("native")
local hudCalls = {}
local hostHud = H.obj("UI_Player_Interface_C", {
    ["Change Money Value"] = function(_, change, new) hudCalls[#hudCalls + 1] = { "money", change, new } end,
    ["Change XP Value"]    = function(_, change, new) hudCalls[#hudCalls + 1] = { "xp", change, new } end,
})
local gm = H.spawn("Core_Gamemode_C", { Money = 320960852, Experience = 7112, ["UI Game Interface"] = hostHud })
local tool = 1
local seller = H.spawn("Player_Character_C", {
    ["Look At Test"] = function() end,
    ["Trace from Camera Stop looking At"] = function() end,
    ["Current Tool in hand"] = 1,
    ["InpActEvt_Input_Sell_K2Node_EnhancedInputActionEvent_0"] = function(self)
        gm.Money = gm.Money + 1000              -- Change Money, as Init Sell does it
        self["Current Tool in hand"] = 0       -- and Throw puts the hand tool back
    end,
    GetAddress = function() return 0x9200 end,
})
rpcGuestPC.Pawn = seller
rpcGuestPC.GetAddress = function() return 0x9100 end
hostPC.GetAddress = function() return 0x9000 end
local hostPawnForHud = H.obj("Player_Character_C", { GetAddress = function() return 0x9300 end })
local savedHostPawn = hostPC.Pawn
hostPC.Pawn = hostPawnForHud
for _, p in ipairs({ "GetPlayerController", "GetPlayerCharacter", "GetPlayerPawn", "GetPlayerCameraManager" }) do
    H.staticObjects["/Script/Engine.GameplayStatics:" .. p] = H.obj("Function", { __isActor = false,
        GetAddress = function() return 0xA000 end })
end
local windows = 0
Native._fake({
    rt_version = function() return 2, "RewindNative (fake)" end,
    rt_hook_return = function() return 0xD8 end,
    rt_redirect_begin = function() windows = windows + 1 return 0 end,
    rt_redirect_end = function() return 2 end,
    rt_unhook_all = function() return 0 end,
    rt_stats = function() return 4, 0xD8, 0, 0 end,
    rt_read_ptr = function() return nil end,
})
H.world.objects["Core_Gamemode_C"] = { gm }
UE.beginFrame()
upHook(rpcGuestPC, { X = 1480, Y = -1700, Z = 152 }, UE.rotArg({ Pitch = -27, Yaw = -90, Roll = 106 }))
Chan.pump()
check("a guest's sale is replayed inside a guest window", windows == 1, ("%d window(s)"):format(windows))
check("and the host's HUD is given the new total",
      gm["UI Game Interface"] == hostHud and hudCalls[1] and hudCalls[1][1] == "money"
      and hudCalls[1][2] == 1000 and hudCalls[1][3] == 320961852,
      hudCalls[1] and table.concat({ tostring(hudCalls[1][1]), tostring(hudCalls[1][2]), tostring(hudCalls[1][3]) }, " ") or "no HUD call")
check("XP that did not change is not touched", #hudCalls == 1, ("%d HUD call(s)"):format(#hudCalls))

-- The host decides which tool the guest holds now (Throw put the hand back),
-- and tells that guest.
sentBefore = #sentStrings
GuestInput2.tickHost()
-- Not the last string: the placement preview's word follows it.
local me = ""
for i = sentBefore + 1, #sentStrings do
    if sentStrings[i]:find("RT1|me", 1, true) then me = sentStrings[i] end
end
check("the guest is told the tool its pawn holds on the host",
      #sentStrings > sentBefore and me:find("RT1|me", 1, true) ~= nil and me:find("tool=0", 1, true) ~= nil,
      tostring(me))
-- The guest's own pawn still thinks it holds the move tool.
local changed = {}
local mine = H.obj("Player_Character_C", { ["Current Tool in hand"] = 1,
    ["Change Tool"] = function(self, t) changed[#changed + 1] = t self["Current Tool in hand"] = t end })
hostPC.Pawn = mine
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, me)
Chan.pump()
check("and adopts it through the pawn's own Change Tool", changed[1] == 0 and mine["Current Tool in hand"] == 0,
      ("Change Tool called with %s"):format(tostring(changed[1])))

-- The till. MEASURED: a guest's click on the register did nothing on the
-- host (player 0's "Walking Mapping Context is Enable" is false on a remote
-- controller), and the glide into the register moves GetPlayerPawn(0) on a
-- timeline - the host, once the replay has returned.
H.theWorld.NetDriver.ServerConnection = nil
hostPC.Pawn = hostPawnForHud
-- rpcchan merges repeats of one action from one guest inside 0.12 s of
-- os.clock() (CPU time): on a fast run this section's first click fell inside
-- the window of an earlier test's. A clock that only moves when told to.
local realClock = os.clock
local fakeNow = realClock() + 100
os.clock = function() return fakeNow end
local function later() fakeNow = fakeNow + 1 end
local tillCalls = {}
local function timeline(name)
    return H.obj("TimelineComponent", { __isActor = false, playing = false,
        IsPlaying = function(self) return self.playing end,
        Stop = function(self) self.playing = false tillCalls[#tillCalls + 1] = "stop " .. name end })
end
local tlIn, tlOut = timeline("in"), timeline("out")
local till = H.spawn("MembershipMachine_C", {
    ["Player In Checkout Mode"] = false, ["Player is currently moving"] = false,
    ["Timeline Move User to Membership"] = tlIn, ["Timeline Move User out Membership"] = tlOut,
    K2_GetActorLocation = function() return { X = 1643, Y = -1557, Z = 90 } end,
    ["Toggle Checkout Mode"] = function(self, on)
        tillCalls[#tillCalls + 1] = "toggle " .. tostring(on)
        self["Player In Checkout Mode"] = on
        self["Player is currently moving"] = true
        if on then tlIn.playing = true else tlOut.playing = true end
    end,
    ["Timeline Move User to Membership__FinishedFunc"] = function(self)
        tillCalls[#tillCalls + 1] = "finish in" self["Player is currently moving"] = false end,
    ["Timeline Move User out Membership__FinishedFunc"] = function(self)
        tillCalls[#tillCalls + 1] = "finish out" self["Player is currently moving"] = false end,
})
seller["Current Tool in hand"] = 0
seller["InpActEvt_Input_Main-Trigger_K2Node_EnhancedInputActionEvent_20"] = function() end
UE.beginFrame()
later()
upHook(rpcGuestPC, { X = 1470, Y = -1660, Z = 152 }, UE.rotArg({ Pitch = -12, Yaw = 31, Roll = 101 }))
Chan.pump()
check("a guest's click on the register puts that guest at the till", till["Player In Checkout Mode"] == true
      and tillCalls[1] == "toggle true", table.concat(tillCalls, ", "))
check("the glide that would drag the host is stopped, and finished as the guest",
      tillCalls[2] == "stop in" and tillCalls[3] == "finish in" and till["Player is currently moving"] == false,
      table.concat(tillCalls, ", "))
sentBefore = #sentStrings
GuestInput2.tickHost()
local told = nil
for i = sentBefore + 1, #sentStrings do if sentStrings[i]:find("RT1|me", 1, true) then told = sentStrings[i] end end
check("and the guest's own game is told to follow", told ~= nil and told:find("till=1", 1, true) ~= nil, tostring(told))

-- The cash drawer: on the host it slid open, on a guest it stayed shut.
local hostCo = H.spawn("CheckOut_C", { ["Checkout Draw is open"] = true, ["User can close the Cash Drawer"] = false,
    ["Actual Payback"] = 0, ["Money receive"] = 2500, ["Money to Payback"] = 400, ["Total of bill"] = 2100 })
UE._resetLookups()      -- an earlier tick looked for a CheckOut_C, found none, and backed off
UE.beginFrame()
sentBefore = #sentStrings
GuestInput2.tickHost()
local tillMsg = nil
for i = sentBefore + 1, #sentStrings do if sentStrings[i]:find("RT1|till", 1, true) then tillMsg = sentStrings[i] end end
check("the host's cash drawer goes to the guests", tillMsg ~= nil and tillMsg:find("p=400", 1, true) ~= nil,
      tostring(tillMsg))
local drawerComp = H.obj("SceneComponent", { __isActor = false,
    K2_SetRelativeLocation = function(self, v) self.rel = v end })
local refreshed = 0
local guestCo = H.obj("CheckOut_C", { ["Checkout Draw is open"] = false, ["cash drawer"] = drawerComp,
    ["Refresh Display"] = function() refreshed = refreshed + 1 end })
H.world.objects["CheckOut_C"] = { guestCo }
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, tillMsg or "")
Chan.pump()
check("the guest's drawer opens where the host's is, with the same numbers",
      guestCo["Checkout Draw is open"] == true and drawerComp.rel and drawerComp.rel.Y == 35
      and guestCo["Money to Payback"] == 400 and guestCo["Money receive"] == 2500 and refreshed == 1,
      ("open=%s Y=%s due=%s refreshed=%d"):format(tostring(guestCo["Checkout Draw is open"]),
       tostring(drawerComp.rel and drawerComp.rel.Y), tostring(guestCo["Money to Payback"]), refreshed))
H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["CheckOut_C"] = nil
UE.beginFrame()

-- W on the guest: the machine's own binding, so the host hears it as action 7.
tillCalls = {}
later()
upHook(rpcGuestPC, { X = 1718, Y = -1486, Z = 150 }, UE.rotArg({ Pitch = 0, Yaw = 180, Roll = 107 }))
Chan.pump()
check("leaving the till on the guest leaves it on the host, the same way",
      till["Player In Checkout Mode"] == false and tillCalls[1] == "toggle false"
      and tillCalls[2] == "stop out" and tillCalls[3] == "finish out", table.concat(tillCalls, ", "))

-- What the guest picked in the skin picker (action 8: place, tool, choice).
local chosen = {}
local skinWall = H.spawn("Wall_C", {
    AC_MeshSkin = H.obj("AC_MeshSkin_C", { __isActor = false, ["Current Mesh Use"] = 0, ["Current Skin Use"] = 1 }),
    K2_GetActorLocation = function() return { X = 1500, Y = -1800, Z = 0 } end,
    ["Set new Skin"] = function(_, id) chosen[#chosen + 1] = id end })
UE.beginFrame()
later()
upHook(rpcGuestPC, { X = 1500, Y = -1800, Z = 0 }, UE.rotArg({ Pitch = 3, Yaw = 4, Roll = 108 }))
Chan.pump()
check("what a guest picks in the skin picker is set on the host's copy", chosen[1] == 4, tostring(chosen[1]))

-- The end-of-day summary is up on the host: about 4 s in, the game makes the
-- front door usable again, and a guest shutting it would start a second end
-- of the day.
gm["End of Day Interface"] = H.obj("UI_EndOfTheDay_C", { __isActor = false, IsInViewport = function() return true end })
local rmb = 0
seller["InpActEvt_Input_Secondary-Trigger_K2Node_EnhancedInputActionEvent_23"] = function() rmb = rmb + 1 end
local windowsBefore = windows
UE.beginFrame()
later()
upHook(rpcGuestPC, { X = 1360, Y = -1250, Z = 152 }, UE.rotArg({ Pitch = -10, Yaw = 113, Roll = 102 }))
Chan.pump()
check("while the end-of-day summary is up a guest's press is not replayed",
      rmb == 0 and windows == windowsBefore, ("%d press(es) replayed"):format(rmb))
gm["End of Day Interface"] = nil

os.clock = realClock
for _, pair in ipairs({ { "MembershipMachine_C", till }, { "CheckOut_C", hostCo }, { "Wall_C", skinWall } }) do
    for i, o in ipairs(H.world.objects[pair[1]] or {}) do
        if o == pair[2] then table.remove(H.world.objects[pair[1]], i) break end
    end
end

H.theWorld.NetDriver.ServerConnection = nil
hostPC.Pawn = savedHostPawn
rpcGuestPC.Pawn = nil
H.world.objects["Core_Gamemode_C"] = {}
for i, o in ipairs(H.world.objects["Player_Character_C"] or {}) do
    if o == seller then table.remove(H.world.objects["Player_Character_C"], i) break end
end
Native._fake(nil)
GuestInput2.reset()
UE.beginFrame()
end

do
print("\n-- shelf titles and text signs --")
-- REPORTED: every shelf title on a guest read "Default Text". The shelf works
-- its title's genre out from the tapes its containers hold, and on a guest
-- they hold nothing (not replicated): genre 0, empty - the placeholder tile.
local SkinSync = require("skinsync")
SkinSync.reset()
local function title(x, y, z, g, t, e, v, yaw)
    local o = H.spawn("ShelveTitle_C", { Genre = g, ["Special Tag"] = t, ["Empty Shelf"] = e,
        ["Shelf Title Visiblity"] = v, calls = {},
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        K2_GetActorRotation = function() return { pitch = 0, Yaw = yaw or 90, Roll = 0 } end })
    o["Update Material"] = function(self, gg, tt, ee)
        self.calls[#self.calls + 1] = ("update %d %d %s"):format(gg, tt, tostring(ee))
        self.Genre, self["Special Tag"], self["Empty Shelf"] = gg, tt, ee
    end
    o["Shelve Title Visiblity"] = function(self, vv)
        self.calls[#self.calls + 1] = "visible " .. tostring(vv)
        self["Shelf Title Visiblity"] = vv
    end
    return o
end
local savedTitles = H.world.objects["ShelveTitle_C"]
H.world.objects["ShelveTitle_C"] = {}
title(1500, -1800, 210, 5, 0, false, true)        -- a drama shelf
title(1600, -1800, 210, 3, 1, true, false)        -- an empty one, its title hidden
title(1700, -1800, 210, 7, 0, false, true)
title(1700, -1800, 210, 4, 0, true, true, -90)    -- the other face of a double-sided shelf
title(0, 0, -5000, 9, 0, false, true)             -- packed in a box: not sent
-- A sign the player wrote over the snacks: its words come from the save.
local function textSign(x, y, z, words)
    local o = H.spawn("TextSign_C", { ["User Text"] = FText(words), updates = 0,
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        K2_GetActorRotation = function() return { pitch = 0, Yaw = -90, Roll = 0 } end })
    o["Update Text"] = function(self) self.updates = self.updates + 1 end
    return o
end
local savedSigns = H.world.objects["TextSign_C"]
H.world.objects["TextSign_C"] = {}
textSign(767, -1808, 184, "SNACKS")
H.theWorld.NetDriver.ServerConnection = nil
UE.beginFrame()
local sentBefore = #sentStrings
SkinSync.tickHost(5000)
local titlesMsg, signsMsg = nil, nil
for i = sentBefore + 1, #sentStrings do
    if sentStrings[i]:find("RT1|titles", 1, true) then titlesMsg = sentStrings[i] end
    if sentStrings[i]:find("RT1|signs", 1, true) then signsMsg = sentStrings[i] end
end
check("and every text sign's words", signsMsg ~= nil and signsMsg:find("767;-1808;184;270;SNACKS", 1, true) ~= nil,
      tostring(signsMsg))
check("the host sends every shelf title's genre, tag, emptiness and visibility",
      titlesMsg ~= nil and titlesMsg:find("1500;-1800;210;90;5;0;0;1", 1, true) ~= nil
      and titlesMsg:find("1600;-1800;210;90;3;1;1;0", 1, true) ~= nil
      and titlesMsg:find("1700;-1800;210;270;4;0;1;1", 1, true) ~= nil, tostring(titlesMsg))
check("but not the titles of shelves packed away below the floor",
      titlesMsg ~= nil and titlesMsg:find("-5000", 1, true) == nil, tostring(titlesMsg))

-- The guest: its own titles, as the guest's shelves left them.
H.world.objects["ShelveTitle_C"] = {}
local g1 = title(1500, -1800, 210, 0, 0, true, true)
local g2 = title(1600.003, -1800, 210, 0, 0, true, true)
local g3 = title(1700, -1800, 210, 7, 0, false, true)   -- happens to agree already
local g4 = title(1700, -1800, 210, 0, 0, false, true, -90)
H.world.objects["TextSign_C"] = {}
local gSign = textSign(767.002, -1808, 184, "Default Text")
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
-- FText properties are written through KismetSystemLibrary SetTextPropertyByName
-- (UE.setText): a plain FText write overruns by 8 bytes on this build.
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = H.obj("KismetSystemLibrary", { __isActor = false,
    SetTextPropertyByName = function(_, obj, name, text) obj[name:ToString()] = text end })
UE._resetLookups()
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, titlesMsg or "")
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, signsMsg or "")
Chan.pump()
SkinSync.tickGuest(6000)
check("a guest title is given the host's values through its own Update Material",
      g1.calls[1] == "update 5 0 false", table.concat(g1.calls, ", "))
check("an empty shelf's title stays empty, and a hidden one is hidden",
      g2.calls[1] == "update 3 1 true" and g2.calls[2] == "visible false", table.concat(g2.calls, ", "))
check("each title is dressed once even where it agrees (its own may never have run)",
      #g3.calls == 1 and g3.calls[1] == "update 7 0 false", table.concat(g3.calls, ", "))
check("the two faces of a double-sided shelf are told apart by the way they face",
      g4.calls[1] == "update 4 0 true", table.concat(g4.calls, ", "))
check("a guest's text sign says the host's words, drawn by its own Update Text",
      gSign["User Text"]:ToString() == "SNACKS" and gSign.updates == 1,
      gSign["User Text"]:ToString() .. (" (%d update(s))"):format(gSign.updates))
SkinSync.tickGuest(6020)
check("a title that still shows the host's values is left alone", #g1.calls == 1 and #g3.calls == 1,
      ("%d / %d calls"):format(#g1.calls, #g3.calls))
-- The guest's own shelf works its genre out again (a container event).
g1.Genre, g1["Empty Shelf"] = 0, true
SkinSync.tickGuest(6040)
check("one the guest's own shelf changed back is given the host's values again",
      #g1.calls == 2 and g1.calls[2] == "update 5 0 false", table.concat(g1.calls, ", "))

H.theWorld.NetDriver.ServerConnection = nil
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = nil
UE._resetLookups()
H.world.objects["ShelveTitle_C"] = savedTitles
H.world.objects["TextSign_C"] = savedSigns
SkinSync.reset()
UE.beginFrame()
end

do
print("\n-- film posters --")
-- A poster's film is its "Specific SKU", from the host's save. A guest never
-- loads the save, and with SKU 0 the poster rolls a random film of its own.
local SkinSync = require("skinsync")
SkinSync.reset()
local function poster(x, y, z, sku, yaw)
    local o = H.spawn("PosterFrame_C", { ["Specific SKU"] = sku, applied = {},
        K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
        K2_GetActorRotation = function() return { pitch = 0, Yaw = yaw, Roll = 0 } end })
    o["Apply Material for Film based on SKU"] = function(self, force)
        self.applied[#self.applied + 1] = ("%d %s"):format(self["Specific SKU"], tostring(force))
    end
    return o
end
local savedPosters = H.world.objects["PosterFrame_C"]
H.world.objects["PosterFrame_C"] = {}
poster(900, -1200, 150, 41207, 180)
poster(950, -1200, 150, 0, 180)             -- no film picked yet: nothing to say
H.theWorld.NetDriver.ServerConnection = nil
UE._resetLookups()
UE.beginFrame()
local sentBefore = #sentStrings
SkinSync.tickHost(8000)
local postersMsg = nil
for i = sentBefore + 1, #sentStrings do
    if sentStrings[i]:find("RT1|posters", 1, true) then postersMsg = sentStrings[i] end
end
check("the host sends each poster's film, by place and facing",
      postersMsg ~= nil and postersMsg:find("900;-1200;150;180;41207", 1, true) ~= nil
      and postersMsg:find("950;", 1, true) == nil, tostring(postersMsg))

-- The guest's copy of that poster, showing the film its own load rolled.
H.world.objects["PosterFrame_C"] = {}
local gp = poster(900.004, -1200, 150, 33001, 180)
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, postersMsg or "")
Chan.pump()
SkinSync.tickGuest(9000)
check("a guest's poster shows the host's film, drawn by its own Apply Material for Film",
      gp["Specific SKU"] == 41207 and gp.applied[1] == "41207 false", table.concat(gp.applied, ", "))
SkinSync.tickGuest(9020)
check("and is left alone while it shows it", #gp.applied == 1, ("%d apply(s)"):format(#gp.applied))

H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["PosterFrame_C"] = savedPosters
SkinSync.reset()
UE._resetLookups()
UE.beginFrame()
end

do
print("\n-- the register: its screen and the change on the counter --")
local GuestInput3 = require("guestinput")
GuestInput3.reset()
local function textBlock(s)
    return H.obj("TextBlock", { __isActor = false, Text = FText(s),
        SetText = function(self, t) self.Text = t end })
end
local function material(name)
    local m = H.obj("Material", { __isActor = false })
    m.GetFName = function() return FName(name) end
    return m
end

-- The host's machine: a customer's bill on the screen.
local hostLines = {
    H.obj("UI_Screen_ProductScan_C", { __isActor = false, Name = "RAIN WOMAN", Price = 3.5, ProductType = 1,
        txt_Tag = H.obj("MultiLineEditableText", { __isActor = false, Text = FText("NEW"), Visibility = 0 }) }),
    H.obj("UI_Screen_Checkout_Fees_C", { __isActor = false, Name = "Late fee", Price = 1.25, ["Fees Error Type"] = 2 }),
}
local hostBox = H.obj("ScrollBox", { __isActor = false,
    GetChildrenCount = function() return #hostLines end,
    GetAllChildren = function() return hostLines end })
local hostW = H.obj("UI_Screen_Membership_Widget_C", { __isActor = false,
    ScrollBox_ScanProduct = hostBox,
    WidgetSwitcher = H.obj("WidgetSwitcher", { __isActor = false, ActiveWidgetIndex = 1 }),
    ["Price Total"] = 4.75,
    ["txt_Member-name_checkoutpage"] = textBlock("Ada Lovelace"),
    ["txt_Member-Membership_checkoutpage"] = textBlock("0042"),
    txt_desktop_date = textBlock("Monday 3, Spring"),
    TextBlock_StoreName = textBlock("BLOCKBUSTED") })
local hostScreen = material("M_CheckoutScreen")
local hostTill = H.spawn("MembershipMachine_C", {
    Widget = H.obj("WidgetComponent", { __isActor = false, GetWidget = function() return hostW end }),
    LA_CashRegister_A_03 = H.obj("StaticMeshComponent", { __isActor = false,
        GetMaterial = function() return hostScreen end }) })
-- The change the guest counted: one bill on the counter, one stack in the drawer.
local function money(onTable)
    return H.spawn("Money_10bucks_C", { bReplicates = false, bReplicateMovement = false, onTable = onTable,
        GetLocalRole = function() return 3 end,
        SetReplicates = function(self, v) self.setWhileOff = (self.bReplicates == false) self.bReplicates = v end,
        SetReplicateMovement = function(self, v) self.bReplicateMovement = v end,
        FlushNetDormancy = function() end })
end
local counted, stack = money(true), money(false)
local hostCo = H.spawn("CheckOut_C", { ["Checkout Draw is open"] = true, ["User can close the Cash Drawer"] = false,
    ["Actual Payback"] = 1000, ["Money receive"] = 2500, ["Money to Payback"] = 400, ["Total of bill"] = 2100,
    ["Array of Spawned Money on table ref"] = { counted } })
H.theWorld.NetDriver.ServerConnection = nil
UE._resetLookups()
UE.beginFrame()
local sentBefore = #sentStrings
GuestInput3.tickHost()
local billMsg = nil
for i = sentBefore + 1, #sentStrings do
    if sentStrings[i]:find("RT1|bill", 1, true) then billMsg = sentStrings[i] end
end
check("the host sends the register's bill to the guests",
      billMsg ~= nil and billMsg:find("Ada Lovelace", 1, true) ~= nil
      and billMsg:find("p\tRAIN WOMAN\t3.50\t1\tNEW", 1, true) ~= nil
      and billMsg:find("f\tLate fee\t1.25\t2\t", 1, true) ~= nil, tostring(billMsg))
check("the change counted onto the counter is made to replicate - SetReplicates first",
      counted.bReplicates == true and counted.setWhileOff == true and counted.bReplicateMovement == true,
      ("bReplicates=%s set while off=%s"):format(tostring(counted.bReplicates), tostring(counted.setWhileOff)))
check("the drawer's own stacks are left alone (every machine has them)", stack.bReplicates == false,
      tostring(stack.bReplicates))

-- The guest's machine: the desktop page, the screensaver on.
local calls = {}
local guestLines = {}
local guestBox = H.obj("ScrollBox", { __isActor = false,
    GetChildrenCount = function() return #guestLines end,
    GetChildAt = function(_, i) return guestLines[i + 1] end,
    AddChild = function(_, line)
        calls[#calls + 1] = ("product %s %.2f %d"):format(line.Name, line.Price, line.ProductType)
        guestLines[#guestLines + 1] = line
    end })
-- The guest builds a product's line itself (no TSet parameter from Lua):
-- the widget library makes it, KismetSystemLibrary's *ByName setters fill it.
local PRODUCT_LINE = "/Game/VideoStore/asset/prop/CheckOut/UI_Screen_ProductScan.UI_Screen_ProductScan_C"
H.staticObjects[PRODUCT_LINE] = H.obj("WidgetBlueprintGeneratedClass", { __isActor = false })
H.staticObjects["/Script/UMG.Default__WidgetBlueprintLibrary"] = H.obj("WidgetBlueprintLibrary", { __isActor = false,
    Create = function()
        return H.obj("UI_Screen_ProductScan_C", { __isActor = false,
            txt_Tag = H.obj("MultiLineEditableText", { __isActor = false, Visibility = 1,
                SetText = function(self, t) self.Text = t end,
                SetVisibility = function(self, v) self.Visibility = v end }) })
    end })
local function byName(_, obj, name, v) obj[name:ToString()] = v end
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = H.obj("KismetSystemLibrary", { __isActor = false,
    SetStringPropertyByName = byName, SetDoublePropertyByName = byName, SetBytePropertyByName = byName })
local setCalls = 0
local guestSwitcher = H.obj("WidgetSwitcher", { __isActor = false, ActiveWidgetIndex = 0 })
local guestW = H.obj("UI_Screen_Membership_Widget_C", { __isActor = false,
    ScrollBox_ScanProduct = guestBox, WidgetSwitcher = guestSwitcher,
    ["txt_Member-name_checkoutpage"] = textBlock(""), ["txt_Member-Membership_checkoutpage"] = textBlock(""),
    txt_desktop_date = textBlock(""), TextBlock_StoreName = textBlock(""),
    ["Clear Scan Product list"] = function() guestLines = {} calls[#calls + 1] = "clear" end,
    -- Never called: its tags are a TSet parameter (the guest hung once).
    ["Add Product Scanned to the list"] = function() setCalls = setCalls + 1 end,
    ["Set Price Total to interface"] = function(self, total) self.shownTotal = total end,
    ["Add Fees to the list"] = function(_, name, price, kind)
        calls[#calls + 1] = ("fee %s %.2f %d"):format(name, price, kind)
    end,
    ["Switch Widget Page"] = function(_, p) guestSwitcher.ActiveWidgetIndex = p end })
local guestScreen = material("M_Monitor_SaveScreen")
local refreshed = 0
local guestTill = H.obj("MembershipMachine_C", {
    Widget = H.obj("WidgetComponent", { __isActor = false, GetWidget = function() return guestW end }),
    LA_CashRegister_A_03 = H.obj("StaticMeshComponent", { __isActor = false,
        GetMaterial = function() return guestScreen end }),
    ["Set Rest Screen"] = function(_, rest)
        calls[#calls + 1] = "rest " .. tostring(rest)
        guestScreen = material(rest and "M_Monitor_SaveScreen" or "M_CheckoutScreen")
    end,
    ["Refresh Monitor"] = function() refreshed = refreshed + 1 end })
local savedTills = H.world.objects["MembershipMachine_C"]
H.world.objects["MembershipMachine_C"] = { guestTill }
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE._resetLookups()
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, billMsg or "")
Chan.pump()
check("the guest's screen gets the same lines, with their prices and types",
      calls[1] == "clear" and calls[2] == "product RAIN WOMAN 3.50 1" and calls[3] == "fee Late fee 1.25 2"
      and guestW.shownTotal == 4.75, table.concat(calls, ", ") .. " total " .. tostring(guestW.shownTotal))
check("and no TSet ever crosses from Lua (the game's own add-a-product function takes one)",
      setCalls == 0, ("called %d time(s)"):format(setCalls))
local tag = guestLines[1] and guestLines[1].txt_Tag
check("a product's tag line is put back as the host's line drew it",
      tag ~= nil and tag.Text ~= nil and tag.Text:ToString() == "NEW" and tag.Visibility == 0
      and guestLines[1]["Tag text"] == "NEW", tag and tostring(tag.Text and tag.Text:ToString()) or "no line")
check("the member, the page and the desktop's texts follow",
      guestSwitcher.ActiveWidgetIndex == 1
      and guestW["txt_Member-name_checkoutpage"].Text:ToString() == "Ada Lovelace"
      and guestW.TextBlock_StoreName.Text:ToString() == "BLOCKBUSTED",
      ("page %s"):format(tostring(guestSwitcher.ActiveWidgetIndex)))
check("the screen is switched on and captured again", calls[4] == "rest false" and refreshed == 1,
      table.concat(calls, ", ") .. (" refreshed=%d"):format(refreshed))
local before = #calls
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, billMsg or "")
Chan.pump()
check("the same bill again changes nothing", #calls == before and refreshed == 1,
      ("%d new call(s)"):format(#calls - before))

H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["MembershipMachine_C"] = savedTills
H.staticObjects[PRODUCT_LINE] = nil
H.staticObjects["/Script/UMG.Default__WidgetBlueprintLibrary"] = nil
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = nil
for _, pair in ipairs({ { "MembershipMachine_C", hostTill }, { "CheckOut_C", hostCo },
                        { "Money_10bucks_C", counted }, { "Money_10bucks_C", stack } }) do
    for i, o in ipairs(H.world.objects[pair[1]] or {}) do
        if o == pair[2] then table.remove(H.world.objects[pair[1]], i) break end
    end
end
GuestInput3.reset()
UE._resetLookups()
UE.beginFrame()
end

do
print("\n-- a customer paying: the cash in the hand, the basket put away --")
-- REPORTED: on a guest, customers handed over their basket instead of money.
local NpcSync = require("npcsync")
NpcSync.reset()
sentStrings = {}
local stash = H.spawn("Money_NPC-Stash_C", { bReplicates = false, bReplicateMovement = false,
    GetLocalRole = function() return 3 end,
    SetReplicates = function(self, v) self.setWhileOff = (self.bReplicates == false) self.bReplicates = v end,
    SetReplicateMovement = function(self, v) self.bReplicateMovement = v end,
    FlushNetDormancy = function() end })
local payer = H.spawn("AI_Client_Character_C", {
    ["Current Task"] = 4, ["Sub Task"] = 1, ["Pick Up Level"] = 0, ["Has Basket"] = false,
    ["Is Holding something"] = false, ["Current Emotion"] = 0, ["Money Stash"] = stash,
    K2_GetActorLocation = function() return { X = 1700, Y = -1500, Z = 90 } end })
H.theWorld.NetDriver.ServerConnection = nil
UE._resetLookups()
UE.beginFrame()
NpcSync.tickHost(5000.0)
check("the host makes the cash a customer holds out replicate - SetReplicates first",
      stash.bReplicates == true and stash.setWhileOff == true,
      ("bReplicates=%s set while off=%s"):format(tostring(stash.bReplicates), tostring(stash.setWhileOff)))
local npcWire = nil
for _, w in ipairs(sentStrings) do
    if w:find("|npcs|", 1, true) then npcWire = w end
end

-- The guest's copy of that customer still shows the basket it came in with.
H.world.objects["AI_Client_Character_C"], H.world.objects["Money_NPC-Stash_C"] = nil, nil
local toggled = {}
local guestPayer = H.spawn("AI_Client_Character_C", { ["Has Basket"] = true,
    K2_GetActorLocation = function() return { X = 1710, Y = -1505, Z = 90 } end,
    ["Toggle Visiblity Basket"] = function(self, v) toggled[#toggled + 1] = v self["Has Basket"] = v end })
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, npcWire or "")
Chan.pump()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, npcWire or "")
Chan.pump()
check("the guest's customer puts its basket away as the host's did (the game's own toggle, once)",
      #toggled == 1 and toggled[1] == false and guestPayer["Has Basket"] == false,
      ("%d toggle(s), first %s"):format(#toggled, tostring(toggled[1])))
H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["AI_Client_Character_C"] = nil
NpcSync.reset()
UE._resetLookups()
UE.beginFrame()
end

do
print("\n-- build mode: a guest's placement preview --")
-- A guest carrying packed furniture saw no preview: the pick-up ran on the
-- host, whose copy of the guest's ghost got the mesh (and is hidden there).
local GuestInput4 = require("guestinput")
local Native = require("native")
GuestInput4.reset()
local GHOST_FN = "/Game/VideoStore/core/pawn/Player_Character.Player_Character_C:ReceiveTick"
local CLASS = "/Game/VideoStore/asset/prop/shelve/Shelve_Wood.Shelve_Wood_C"
local MESH = "/Game/VideoStore/asset/meshes/SM_Shelf_Wood.SM_Shelf_Wood"
local cdo = H.obj("Shelve_Wood_C", {})
local function furniture(fields)
    local o = H.spawn("Shelve_Wood_C", fields or {})
    o.GetClass = function() return { IsValid = function() return true end,
        GetFullName = function() return "BlueprintGeneratedClass " .. CLASS end,
        GetCDO = function() return cdo end } end
    return o
end
local mesh = H.obj("StaticMesh", { __isActor = false })
mesh.GetFullName = function() return "StaticMesh " .. MESH end
H.staticObjects[MESH] = mesh

-- The host: the guest's pawn carries a box with a shelf in it.
local turned = {}
local hostGhost = H.obj("GhostMesh_C", { Mesh = mesh, ["Can be place on Floor"] = true,
    ["Can be place on Wall"] = false, ["Can be place on Ceilling"] = false,
    ["Ghost Rotation"] = { Pitch = 0, Yaw = 90, Roll = 0 }, bHidden = true,
    NavCollisionZone = H.obj("ChildActorComponent", { __isActor = false, bVisible = true,
        RelativeLocation = { X = 0, Y = 5, Z = 1 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
        RelativeScale3D = { X = 1.5, Y = 1, Z = 1 } }),
    ["Set Rotation of Ghost"] = function(self, r)
        turned[#turned + 1] = r
        self["Ghost Rotation"] = { Pitch = UE.field(r, "Pitch"), Yaw = r.Yaw, Roll = 0 }
    end })
local packed = furniture()
local carrier = H.spawn("Player_Character_C", { Ghost = hostGhost, ["Current Tool in hand"] = 1,
    ["Object Hold"] = H.obj("MovingBox_C", { ["Objects in Inventory"] = { packed } }),
    SetActorTickEnabled = function() end, GetAddress = function() return 0x9500 end })
rpcGuestPC.Pawn = carrier
H.theWorld.NetDriver.ServerConnection = nil
UE.beginFrame()
local sentBefore = #sentStrings
GuestInput4.tickHost()
local ghostMsg = nil
for i = sentBefore + 1, #sentStrings do
    if sentStrings[i]:find("RT1|ghost", 1, true) then ghostMsg = sentStrings[i] end
end
check("the host tells the guest what its pick-up gave the guest's ghost there",
      ghostMsg ~= nil and ghostMsg:find("h=1", 1, true) ~= nil and ghostMsg:find(MESH, 1, true) ~= nil
      and ghostMsg:find(CLASS, 1, true) ~= nil and ghostMsg:find("p=100", 1, true) ~= nil
      and ghostMsg:find("0.00,90.00,0.00", 1, true) ~= nil, tostring(ghostMsg))

-- The guest's own pawn, its own ghost, a shelf of that class in its store.
local ghostCalls = {}
local function rec(s) ghostCalls[#ghostCalls + 1] = s end
local zoneCalls = {}
local guestGhost = H.obj("GhostMesh_C", { ["Ghost Rotation"] = { Pitch = 0, Yaw = 0, Roll = 0 },
    NavCollisionZone = H.obj("ChildActorComponent", { __isActor = false,
        K2_SetRelativeLocationAndRotation = function(_, l) zoneCalls[#zoneCalls + 1] = ("at %.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) end,
        SetRelativeScale3D = function(_, s) zoneCalls[#zoneCalls + 1] = ("scale %.1f"):format(s.X) end,
        SetVisibility = function(_, v) zoneCalls[#zoneCalls + 1] = "visible " .. tostring(v) end,
        ChildActor = nil }),
    ["Set Ghost Mesh"] = function(_, m) rec("mesh " .. (m == mesh and "the shelf's" or tostring(m))) end,
    ["Set placement"] = function(_, f, w, c) rec(("placement %s %s %s"):format(tostring(f), tostring(w), tostring(c))) end,
    ["Set Rotation of Ghost"] = function(self, r)
        rec(("rotation %.0f"):format(r.Yaw))
        self["Ghost Rotation"] = { Pitch = 0, Yaw = r.Yaw, Roll = 0 }
    end,
    ["Set Visibility of Ghost"] = function(_, v) rec("visible " .. tostring(v)) end })
local ticks = {}
local lookAtSays = true                       -- what the game's look-at trace answers
local reaches = {}
local myPawn = H.obj("Player_Character_C", { Ghost = guestGhost,
    ["Object Hold"] = H.obj("MovingBox_C", { ["Objects in Inventory"] = {} }),
    ["Current Tool in hand"] = 0, ["Hand Tool Trace - Distance"] = 180,
    GetAddress = function() return 0x7700 end,
    ["Trace from Camera for LookAt Ghost"] = function(_, box, reach, debugType, out)
        reaches[#reaches + 1] = reach
        out["Show Ghost"] = lookAtSays
    end,
    ["Ghost Tick"] = function(_, arg) ticks[#ticks + 1] = arg end })
local savedHostPawn = hostPC.Pawn
hostPC.Pawn = myPawn
local placed = furniture()                     -- the same kind of shelf, standing in the store
H.staticObjects[GHOST_FN] = H.obj("Function", { __isActor = false })
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE._resetLookups()
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, ghostMsg or "")
Chan.pump()
GuestInput4.tickGuest()
check("the guest's own ghost gets the mesh, where it may stand and the host's rotation",
      ghostCalls[1] == "mesh the shelf's" and ghostCalls[2] == "placement true false false"
      and ghostCalls[3] == "rotation 90", table.concat(ghostCalls, ", "))
check("and the footprint the host's wears", zoneCalls[1] == "at 0,5,1" and zoneCalls[2] == "scale 1.5"
      and zoneCalls[3] == "visible true", table.concat(zoneCalls, ", "))
local frameHook = H.hooks[GHOST_FN]
check("the pawn's tick is hooked for the preview", frameHook ~= nil, "no hook on ReceiveTick")
if frameHook then
    frameHook(myPawn, 0.016)
    frameHook(carrier, 0.016)                 -- another player's pawn ticking here
end
check("each frame the pawn's own Ghost Tick runs, handed the furniture's class default",
      #ticks == 1 and ticks[1] == cdo, ("%d Ghost Tick(s)"):format(#ticks))
check("after the game's own look-at question, at the hand tool's reach",
      reaches[1] == 180, tostring(reaches[1]))
-- Looking at something usable instead (a shelf's slot, the counter): the
-- host would throw the box there, so the guest sees no preview either.
lookAtSays = false
local callsBefore = #ghostCalls
if frameHook then frameHook(myPawn, 0.016) end
check("where the game would show no preview the guest's is hidden and not ticked",
      #ticks == 1 and ghostCalls[#ghostCalls] == "visible false" and #ghostCalls == callsBefore + 1,
      ("%d Ghost Tick(s), last %s"):format(#ticks, tostring(ghostCalls[#ghostCalls])))
lookAtSays = true

-- The mouse wheel turned the guest's preview (the box's Rotate ran here).
guestGhost["Ghost Rotation"] = { Pitch = 0, Yaw = 180, Roll = 0 }
local upBefore = #upSends
UE.beginFrame()
GuestInput4.tickGuest()
local sentTurn = upSends[#upSends]
check("a turn of the furniture goes to the host as action 10",
      #upSends > upBefore and sentTurn and math.abs(UE.field(sentTurn.rot, "Roll") - 110) < 0.01
      and math.abs(UE.field(sentTurn.rot, "Yaw") - 180) < 0.01,
      sentTurn and ("roll %s yaw %s"):format(tostring(UE.field(sentTurn.rot, "Roll")),
                                             tostring(UE.field(sentTurn.rot, "Yaw"))) or "nothing sent")
-- ...where it turns the host's copy of the ghost, which Throw places by.
H.theWorld.NetDriver.ServerConnection = nil
for _, p in ipairs({ "GetPlayerController", "GetPlayerCharacter", "GetPlayerPawn", "GetPlayerCameraManager" }) do
    H.staticObjects["/Script/Engine.GameplayStatics:" .. p] = H.obj("Function", { __isActor = false,
        GetAddress = function() return 0xA000 end })
end
Native._fake({
    rt_version = function() return 2, "RewindNative (fake)" end,
    rt_hook_return = function() return 0xD8 end,
    rt_redirect_begin = function() return 0 end,
    rt_redirect_end = function() return 0 end,
    rt_unhook_all = function() return 0 end,
    rt_stats = function() return 4, 0xD8, 0, 0 end,
    rt_read_ptr = function() return nil end,
})
UE.beginFrame()
upHook(rpcGuestPC, { X = 0, Y = 0, Z = 0 }, UE.rotArg({ Pitch = 0, Yaw = 180, Roll = 110 }))
Chan.pump()
check("the host turns the guest's ghost there", turned[1] ~= nil and math.abs(turned[1].Yaw - 180) < 0.01,
      turned[1] and tostring(turned[1].Yaw) or "not turned")

-- Put down: the host says so, the preview goes and the frames stop.
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, "RT1|ghost|h=0")
Chan.pump()
GuestInput4.tickGuest()
local n = #ticks
if frameHook then frameHook(myPawn, 0.016) end
check("when the host says the box is gone the preview is hidden and the frames stop",
      ghostCalls[#ghostCalls] == "visible false" and #ticks == n, table.concat(ghostCalls, ", "))

H.theWorld.NetDriver.ServerConnection = nil
hostPC.Pawn = savedHostPawn
rpcGuestPC.Pawn = nil
H.staticObjects[GHOST_FN], H.staticObjects[MESH] = nil, nil
for _, o in ipairs({ packed, placed }) do
    for i, x in ipairs(H.world.objects["Shelve_Wood_C"] or {}) do
        if x == o then table.remove(H.world.objects["Shelve_Wood_C"], i) break end
    end
end
for i, o in ipairs(H.world.objects["Player_Character_C"] or {}) do
    if o == carrier then table.remove(H.world.objects["Player_Character_C"], i) break end
end
Native._fake(nil)
GuestInput4.reset()
UE._resetLookups()
UE.beginFrame()
end

do
print("\n-- the end of the day on a guest's screen --")
local DayEnd = require("dayend")
DayEnd.reset()
local SUMMARY = "/Game/VideoStore/core/widget/dayUI/UI_EndOfTheDay.UI_EndOfTheDay_C"
local BANNER = "/Game/VideoStore/core/widget/dayUI/UI_NewDay.UI_NewDay_C"
local function textBlock(s)
    return H.obj("TextBlock", { __isActor = false, Text = FText(s),
        SetText = function(self, t) self.Text = t end })
end
local function panel(s)
    return H.obj("UI_Statistic_MovieRent_C", { __isActor = false, ["Text of Result"] = FText(s), shown = nil,
        ["Set Text"] = function(self) self.shown = self["Text of Result"]:ToString() end })
end

-- The host closes the store: the summary is up, and the level brought a
-- gameplay system (3) and a movie genre (5).
local UNLOCK = "/Game/VideoStore/core/widget/dayUI/UI_Statistic_Levelup_Unlock.UI_Statistic_Levelup_Unlock_C"
local POPUP = "/Game/VideoStore/core/widget/dayUI/UI_GenreUnlock.UI_GenreUnlock_C"
local hostUnlocks = {
    H.obj("UI_Statistic_Levelup_Unlock_C", { __isActor = false, ["Gameplay System"] = 3, ["Movie Genre"] = 0, ["Game Genre"] = 0 }),
    H.obj("UI_Statistic_Levelup_Unlock_C", { __isActor = false, ["Gameplay System"] = 0, ["Movie Genre"] = 5, ["Game Genre"] = 0 }),
}
local hostSummary = H.obj("UI_EndOfTheDay_C", { __isActor = false,
    IsInViewport = function() return true end,
    HorizontalBox_LevelUpUnlock = H.obj("HorizontalBox", { __isActor = false,
        GetChildrenCount = function() return #hostUnlocks end,
        GetChildAt = function(_, i) return hostUnlocks[i + 1] end }),
    UI_Statistic_MovieRent = panel("14"), UI_Statistic_EarningTotal = panel("$412.50"),
    txt_Date = textBlock("Friday 12, Summer"), txt_LevelName = textBlock("Video Club"),
    txt_LevelUp = H.obj("TextBlock", { __isActor = false, Visibility = 1 }),
    ProgressBar_Level = H.obj("ProgressBar", { __isActor = false, Percent = 0.4 }),
    WidgetSwitcher = H.obj("WidgetSwitcher", { __isActor = false, ActiveWidgetIndex = 0 }) })
local gm = H.spawn("Core_Gamemode_C", { ["End of Day Interface"] = hostSummary })
local savedGms = H.world.objects["Core_Gamemode_C"]
H.world.objects["Core_Gamemode_C"] = { gm }
H.theWorld.NetDriver.ServerConnection = nil
UE._resetLookups()
UE.beginFrame()
local sentBefore = #sentStrings
DayEnd.tickHost(7000)
local dayMsg = sentStrings[#sentStrings]
check("the host sends its end-of-day summary to the guests",
      #sentStrings > sentBefore and dayMsg:find("RT1|day", 1, true) ~= nil and dayMsg:find("s=1", 1, true) ~= nil
      and dayMsg:find("t1=14", 1, true) ~= nil and dayMsg:find("Friday 12, Summer", 1, true) ~= nil
      and dayMsg:find("b=0.4000", 1, true) ~= nil, tostring(dayMsg))
check("with what the level unlocked, as the summary's unlock widgets describe it",
      dayMsg:find("u=3.0.0,0.5.0", 1, true) ~= nil, tostring(dayMsg))

-- The guest builds the same widget and fills it in.
local made = {}
local function summaryWidget()
    local inVp = false
    local w = H.obj("UI_EndOfTheDay_C", { __isActor = false,
        UI_Statistic_MovieRent = panel(""), UI_Statistic_EarningTotal = panel(""),
        txt_Date = textBlock(""), txt_LevelName = textBlock(""),
        txt_LevelUp = H.obj("TextBlock", { __isActor = false, Visibility = 0,
            SetVisibility = function(self, v) self.Visibility = v end }),
        ProgressBar_Level = H.obj("ProgressBar", { __isActor = false,
            SetPercent = function(self, p) self.Percent = p end }),
        WidgetSwitcher = H.obj("WidgetSwitcher", { __isActor = false, ActiveWidgetIndex = 0,
            SetActiveWidgetIndex = function(self, i) self.ActiveWidgetIndex = i end }),
        HorizontalBox_LevelUpUnlock = H.obj("HorizontalBox", { __isActor = false, items = {}, clears = 0,
            ClearChildren = function(self) self.items = {} self.clears = self.clears + 1 end,
            AddChildToHorizontalBox = function(self, c) self.items[#self.items + 1] = c end }),
        AddToViewport = function() inVp = true end,
        IsInViewport = function() return inVp end,
        ["Close Animation and auto-destroy"] = function(self) self.closed = true inVp = false end })
    for _, b in ipairs({ "UX_Button_NewDay", "UX_Button_Base", "Button_115" }) do
        w[b] = H.obj("UX_Button_Base_C", { __isActor = false, SetIsEnabled = function(self, e) self.enabled = e end })
    end
    return w
end
local function bannerWidget()
    return H.obj("UI_NewDay_C", { __isActor = false, txt_day = textBlock(""), txt_season = textBlock(""),
        AddToViewport = function() end, Animation = function(self) self.animated = true end })
end
H.staticObjects[SUMMARY] = H.obj("WidgetBlueprintGeneratedClass", { __isActor = false, which = "summary" })
H.staticObjects[BANNER] = H.obj("WidgetBlueprintGeneratedClass", { __isActor = false, which = "banner" })
H.staticObjects[UNLOCK] = H.obj("WidgetBlueprintGeneratedClass", { __isActor = false, which = "unlock" })
H.staticObjects[POPUP] = H.obj("WidgetBlueprintGeneratedClass", { __isActor = false, which = "popup" })
local unlocksMade, popups = 0, {}
H.staticObjects["/Script/UMG.Default__WidgetBlueprintLibrary"] = H.obj("WidgetBlueprintLibrary", { __isActor = false,
    Create = function(_, _, cls)
        if cls.which == "unlock" then
            unlocksMade = unlocksMade + 1
            return H.obj("UI_Statistic_Levelup_Unlock_C", { __isActor = false })
        elseif cls.which == "popup" then
            local p = H.obj("UI_GenreUnlock_C", { __isActor = false,
                AddToViewport = function(self, z) self.z = z end })
            popups[#popups + 1] = p
            return p
        end
        local w = cls.which == "summary" and summaryWidget() or bannerWidget()
        made[#made + 1] = w
        return w
    end })
-- FText properties are written through KismetSystemLibrary SetTextPropertyByName
-- (UE.setText): a plain FText write overruns by 8 bytes on this build.
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = H.obj("KismetSystemLibrary", { __isActor = false,
    SetTextPropertyByName = function(_, obj, name, text) obj[name:ToString()] = text end,
    SetBytePropertyByName = function(_, obj, name, v) obj[name:ToString()] = v end })
UE._resetLookups()
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, dayMsg)
Chan.pump()
local mine = made[1]
check("a guest gets the host's summary on screen, filled in through the panels' own Set Text",
      mine ~= nil and mine.UI_Statistic_MovieRent.shown == "14" and mine.UI_Statistic_EarningTotal.shown == "$412.50"
      and mine.txt_Date.Text:ToString() == "Friday 12, Summer" and mine.ProgressBar_Level.Percent == 0.4,
      mine and tostring(mine.UI_Statistic_MovieRent.shown) or "no widget")
check("what the host's summary hides is hidden here too (\"LEVEL UP!\" when nobody levelled up)",
      mine ~= nil and mine.txt_LevelUp.Visibility == 1, mine and tostring(mine.txt_LevelUp.Visibility) or "no widget")
check("with its buttons greyed out: the next day is the host's to start",
      mine ~= nil and mine.UX_Button_NewDay.enabled == false and mine.UX_Button_Base.enabled == false,
      mine and tostring(mine.UX_Button_NewDay.enabled) or "no widget")
local box = mine and mine.HorizontalBox_LevelUpUnlock
local u1, u2 = box and box.items[1], box and box.items[2]
check("the guest's XP page lists the host's unlocks, each made as the summary makes it",
      box ~= nil and #box.items == 2 and u1["Gameplay System"] == 3 and u1["Movie Genre"] == 0
      and u2["Gameplay System"] == 0 and u2["Movie Genre"] == 5 and u2["Game Genre"] == 0,
      box and ("%d unlock(s)"):format(#box.items) or "no widget")
check("and a movie genre's popup goes up over the summary, with that genre",
      #popups == 1 and popups[1]["Genre Unlock"] == 5 and popups[1].z == 12,
      ("%d popup(s)"):format(#popups))
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, dayMsg)
Chan.pump()
check("the next update fills the same widget in, it does not open another", #made == 1,
      ("%d widget(s)"):format(#made))
check("nor make the unlocks or the popup again", unlocksMade == 2 and #popups == 1 and box.clears == 1,
      ("%d unlock(s), %d popup(s), %d clear(s)"):format(unlocksMade, #popups, box and box.clears or -1))

-- The host starts the next day.
H.theWorld.NetDriver.ServerConnection = nil
gm["End of Day Interface"] = nil
UE.beginFrame()
sentBefore = #sentStrings
DayEnd.tickHost(7002)
local closed = sentStrings[#sentStrings]
local hostBanner = H.spawn("UI_NewDay_C", { __isActor = false,
    txt_day = textBlock("Saturday 13"), txt_season = textBlock("Summer") })
UE.beginFrame()
DayEnd.tickHost(7004)
local banner = sentStrings[#sentStrings]
check("when the host's summary closes the guests are told at once, then given the new day",
      closed:find("s=0", 1, true) ~= nil and banner:find("nd=Saturday 13", 1, true) ~= nil,
      tostring(closed) .. " / " .. tostring(banner))
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, closed)
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, banner)
Chan.pump()
local b = made[2]
check("the guest's summary closes the game's way and the new-day banner plays",
      mine ~= nil and mine.closed == true and b ~= nil and b.animated == true
      and b.txt_day.Text:ToString() == "Saturday 13", b and tostring(b.animated) or "no banner")

H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["Core_Gamemode_C"] = savedGms
for i, o in ipairs(H.world.objects["UI_NewDay_C"] or {}) do
    if o == hostBanner then table.remove(H.world.objects["UI_NewDay_C"], i) break end
end
H.staticObjects[SUMMARY], H.staticObjects[BANNER] = nil, nil
H.staticObjects[UNLOCK], H.staticObjects[POPUP] = nil, nil
H.staticObjects["/Script/UMG.Default__WidgetBlueprintLibrary"] = nil
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = nil
UE._resetLookups()
DayEnd.reset()
UE._resetLookups()
UE.beginFrame()
end

do
print("\n-- what an NPC says, on a guest's screen --")
-- The line over an NPC's head is filled by its own events, which only the
-- host's AI and store logic call.
local NpcSync = require("npcsync")
NpcSync.reset()
local P = "/Game/VideoStore/core/ai/pawn/AI_Base_Character.AI_Base_Character_C:"
local SPEAK, PERM = P .. "AI Talk about a problem", P .. "AI Toggle a permanent problem"
H.staticObjects[SPEAK] = H.obj("Function", { __isActor = false, GetAddress = function() return 0x5100 end })
H.staticObjects[PERM] = H.obj("Function", { __isActor = false, GetAddress = function() return 0x5200 end })
local savedClients = H.world.objects["AI_Client_Character_C"]
H.world.objects["AI_Client_Character_C"] = {}
local talker = H.spawn("AI_Client_Character_C", { ["Current Task"] = 2, ["Sub Task"] = 3, ["Pick Up Level"] = 0,
    ["Has Basket"] = true, ["Is Holding something"] = false, ["Current Emotion"] = 0,
    K2_GetActorLocation = function() return { X = 1500, Y = -1400, Z = 90 } end })
H.theWorld.NetDriver.ServerConnection = nil
UE._resetLookups()
UE.beginFrame()
local before = #sentStrings
NpcSync.tickHost(9500)
check("the host hooks the two events an NPC speaks through", H.hooks[SPEAK] ~= nil and H.hooks[PERM] ~= nil,
      "not hooked")
local stateWire = nil
for i = before + 1, #sentStrings do
    if sentStrings[i]:find("|npcs|", 1, true) then stateWire = sentStrings[i] end
end
-- A customer cannot find a film; another waits at the till.
if H.hooks[SPEAK] then H.hooks[SPEAK](talker, "Where is Rain Woman?", 2.5, nil) end
if H.hooks[PERM] then H.hooks[PERM](talker, FText("Waiting to pay"), true) end
before = #sentStrings
NpcSync.tickHost(9500.1)
local lines = {}
for i = before + 1, #sentStrings do
    if sentStrings[i]:find("|npct|", 1, true) then lines[#lines + 1] = sentStrings[i] end
end
check("what it said goes out from the host's tick, with who said it",
      #lines == 2 and lines[1]:find("Where is Rain Woman?", 1, true) ~= nil and lines[1]:find("t=2.50", 1, true) ~= nil
      and lines[2]:find("Waiting to pay", 1, true) ~= nil and lines[2]:find("v=1", 1, true) ~= nil,
      table.concat(lines, " / "))

-- The guest's copy of that customer, paired by place.
H.world.objects["AI_Client_Character_C"] = {}
local shown = {}
local speech = H.obj("Widget3D_AiSpeakInWorld_C", { __isActor = false,
    ["Set Text and Show Message"] = function(_, s, t) shown[#shown + 1] = ("say %s %.1f"):format(s, t) end,
    ["Set Text And Show Message Permanent"] = function(_, s) shown[#shown + 1] = "keep " .. s end,
    ["Start Animation Hidden Message"] = function() shown[#shown + 1] = "hide" end })
H.spawn("AI_Client_Character_C", {
    K2_GetActorLocation = function() return { X = 1510, Y = -1405, Z = 90 } end,
    Widget3D_AiSpeakInWorld = H.obj("WidgetComponent", { __isActor = false, GetWidget = function() return speech end }) })
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
for _, w in ipairs({ stateWire or "", lines[1] or "", lines[2] or "" }) do
    H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, w)
end
Chan.pump()
check("the guest's copy says it, through the same speech widget",
      shown[1] == "say Where is Rain Woman? 2.5" and shown[2] == "keep Waiting to pay", table.concat(shown, ", "))
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, lines[2] or "")
Chan.pump()
check("a permanent line said again (for late joiners) is not shown again", #shown == 2, table.concat(shown, ", "))

-- The host's customer is served: the permanent line goes.
H.theWorld.NetDriver.ServerConnection = nil
UE.beginFrame()
if H.hooks[PERM] then H.hooks[PERM](talker, FText(""), false) end
before = #sentStrings
NpcSync.tickHost(9501)
local hide = nil
for i = before + 1, #sentStrings do
    if sentStrings[i]:find("|npct|", 1, true) then hide = sentStrings[i] end
end
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, hide or "")
Chan.pump()
check("and when the host's NPC drops it, the guest's does too", shown[3] == "hide", table.concat(shown, ", "))

H.theWorld.NetDriver.ServerConnection = nil
H.world.objects["AI_Client_Character_C"] = savedClients
H.staticObjects[SPEAK], H.staticObjects[PERM] = nil, nil
NpcSync.reset()
UE._resetLookups()
UE.beginFrame()
end

do
print("\n-- a guest's conversation, on the guest's screen --")
-- REPORTED: a guest's right click on the staff member opened the talk dialog
-- on the HOST's screen. The talk is spawned on the host for the guest's pawn.
local TalkSync = require("talksync")
local GuestInput5 = require("guestinput")
local Native = require("native")
TalkSync.reset()
GuestInput5.reset()
local TP = "/Game/VideoStore/core/blueprint/talksystem/"
local BEGIN, ENDFN = TP .. "TalkSystem.TalkSystem_C:ReceiveBeginPlay", TP .. "TalkSystem.TalkSystem_C:End Talk System"
local TALK_UI, ANSWER_UI = TP .. "UI_Talk.UI_Talk_C", TP .. "UI_Talk-Answer.UI_Talk-Answer_C"
local ANSWER_FN = ANSWER_UI .. ":Button Clicked Event"
H.staticObjects[BEGIN] = H.obj("Function", { __isActor = false, GetAddress = function() return 0x6100 end })
H.staticObjects[ENDFN] = H.obj("Function", { __isActor = false, GetAddress = function() return 0x6200 end })
H.theWorld.NetDriver.ServerConnection = nil
UE._resetLookups()
UE.beginFrame()
TalkSync.tickHost(100)
check("the host hooks the talk system's start and end", H.hooks[BEGIN] ~= nil and H.hooks[ENDFN] ~= nil, "not hooked")

-- The host's copy of the guest's pawn, and the talk the staff member started for it.
local function textBlock(s, vis)
    return H.obj("TextBlock", { __isActor = false, Text = FText(s), Visibility = vis or 4,
        GetText = function(self) return self.Text end,
        SetText = function(self, t) self.Text = t end,
        SetVisibility = function(self, v) self.Visibility = v end })
end
local function answer(kind, num, text)
    return H.obj("UI_Talk-Answer_C", { __isActor = false, ["Answer Type"] = kind, ["Number Text"] = num,
        ["Button Text"] = text })
end
local hostAnswers = { answer(2, 1, "Sure, take the day."), answer(1, 2, "Not today.") }
local hostClicks = {}
local hostWidget = H.obj("UI_Talk_C", { __isActor = false, inVp = true,
    IsInViewport = function(self) return self.inVp end,
    RemoveFromParent = function(self) self.inVp = false end,
    txt_talk = textBlock("I'm not feeling well. Can I go home?"),
    txt_NameClient = textBlock("Adam"),
    Zone_ButtonAnswer = H.obj("VerticalBox", { __isActor = false,
        GetChildrenCount = function() return #hostAnswers end,
        GetChildAt = function(_, i) return hostAnswers[i + 1] end }),
    ["Clicked on Answer Button Event"] = function(_, kind) hostClicks[#hostClicks + 1] = kind end })
local guestPawnOnHost = H.spawn("Player_Character_C", {
    IsLocallyControlled = function() return false end,
    GetController = function() return rpcGuestPC end,
    GetAddress = function() return 0x7a00 end })
local stopped = 0
local talk = H.spawn("TalkSystem_C", { Player = guestPawnOnHost, ["Widget Talk"] = hostWidget,
    ["Force Stop LookAt"] = function() stopped = stopped + 1 end })
local savedGuestPawn = rpcGuestPC.Pawn
rpcGuestPC.Pawn = guestPawnOnHost
if H.hooks[BEGIN] then H.hooks[BEGIN](talk) end
check("a talk the host started for a guest stops turning the host's camera and leaves the host's screen",
      stopped == 1 and hostWidget.inVp == false, ("stopped %d, on screen %s"):format(stopped, tostring(hostWidget.inVp)))
local before = #sentStrings
UE.beginFrame()
TalkSync.tickHost(100.5)
local talkMsg = nil
for i = before + 1, #sentStrings do
    if sentStrings[i]:find("RT1|talk", 1, true) then talkMsg = sentStrings[i] end
end
check("and the guest is sent the line, the name and the answers",
      talkMsg ~= nil and talkMsg:find("Can I go home?", 1, true) ~= nil and talkMsg:find("Adam", 1, true) ~= nil
      and talkMsg:find("2\t1\tSure, take the day.", 1, true) ~= nil and talkMsg:find("c=2", 1, true) ~= nil,
      tostring(talkMsg))

-- The guest: the game's own dialog widget, filled in.
local calls = {}
local guestWidget = nil
local madeAnswers = {}
H.staticObjects[TALK_UI] = H.obj("WidgetBlueprintGeneratedClass", { __isActor = false, which = "talk" })
H.staticObjects[ANSWER_UI] = H.obj("WidgetBlueprintGeneratedClass", { __isActor = false, which = "answer" })
H.staticObjects[ANSWER_FN] = H.obj("Function", { __isActor = false, GetAddress = function() return 0x6300 end })
H.staticObjects["/Script/UMG.Default__WidgetBlueprintLibrary"] = H.obj("WidgetBlueprintLibrary", { __isActor = false,
    Create = function(_, _, cls)
        if cls.which == "answer" then
            local a = H.obj("UI_Talk-Answer_C", { __isActor = false })
            madeAnswers[#madeAnswers + 1] = a
            return a
        end
        guestWidget = H.obj("UI_Talk_C", { __isActor = false, inVp = false,
            AddToViewport = function(self, z) self.inVp, self.z = true, z end,
            IsInViewport = function(self) return self.inVp end,
            RemoveFromParent = function(self) self.inVp = false end,
            txt_talk = textBlock(""), txt_NameClient = textBlock("", 1),
            Zone_ButtonAnswer = H.obj("VerticalBox", { __isActor = false, items = {},
                ClearChildren = function(self) self.items = {} end,
                AddChild = function(self, c) self.items[#self.items + 1] = c end }) })
        return guestWidget
    end,
    SetInputMode_UIOnlyEx = function() calls[#calls + 1] = "ui input" end,
    SetInputMode_GameOnly = function() calls[#calls + 1] = "game input" end })
local function byName(_, obj, name, v) obj[name:ToString()] = v end
H.staticObjects["/Script/Engine.Default__KismetSystemLibrary"] = H.obj("KismetSystemLibrary", { __isActor = false,
    SetBytePropertyByName = byName, SetStringPropertyByName = byName, SetIntPropertyByName = byName })
UE._resetLookups()
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, talkMsg or "")
Chan.pump()
local items = guestWidget and guestWidget.Zone_ButtonAnswer.items or {}
check("the guest's screen shows the same dialog, its answers made as UI_Talk makes them",
      guestWidget ~= nil and guestWidget.inVp and guestWidget.txt_talk.Text:ToString() == "I'm not feeling well. Can I go home?"
      and guestWidget.txt_NameClient.Text:ToString() == "Adam" and guestWidget.txt_NameClient.Visibility == 4
      and #items == 2 and items[1]["Answer Type"] == 2 and items[1]["Button Text"] == "Sure, take the day."
      and items[2]["Number Text"] == 2, guestWidget and ("%d answer(s)"):format(#items) or "no widget")
check("with the mouse for it", calls[1] == "ui input" and hostPC.bShowMouseCursor == true,
      table.concat(calls, ", ") .. " cursor " .. tostring(hostPC.bShowMouseCursor))
-- While it is up the guest's clicks answer it; they are not store clicks.
local savedLocalPawn, savedCam = hostPC.Pawn, hostPC.PlayerCameraManager
hostPC.Pawn = H.obj("Player_Character_C", { GetAddress = function() return 0x7b00 end })
hostPC.PlayerCameraManager = H.obj("PlayerCameraManager", { __isActor = false,
    GetAddress = function() return 0x7c00 end,
    GetCameraLocation = function() return { X = 1, Y = 2, Z = 3 } end,
    GetCameraRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end })
local upBefore = #upSends
GuestInput5._onPress(1)
check("the guest's clicks are not sent to the host as store clicks meanwhile", #upSends == upBefore,
      ("%d sent"):format(#upSends - upBefore))
-- The guest clicks "Sure, take the day."
if H.hooks[ANSWER_FN] then H.hooks[ANSWER_FN](items[1]) end
local sent = upSends[#upSends]
check("the answer goes to the host as action 11, its type in the pitch",
      #upSends > upBefore and sent and math.abs(UE.field(sent.rot, "Roll") - 111) < 0.01
      and math.abs(UE.field(sent.rot, "Pitch") - 2) < 0.01,
      sent and ("roll %s pitch %s"):format(tostring(UE.field(sent.rot, "Roll")), tostring(UE.field(sent.rot, "Pitch")))
      or "nothing sent")

-- The host clicks the same answer on its hidden widget, as the guest.
H.theWorld.NetDriver.ServerConnection = nil
for _, p in ipairs({ "GetPlayerController", "GetPlayerCharacter", "GetPlayerPawn", "GetPlayerCameraManager" }) do
    H.staticObjects["/Script/Engine.GameplayStatics:" .. p] = H.obj("Function", { __isActor = false,
        GetAddress = function() return 0xA000 end })
end
Native._fake({
    rt_version = function() return 2, "RewindNative (fake)" end,
    rt_hook_return = function() return 0xD8 end,
    rt_redirect_begin = function() return 0 end,
    rt_redirect_end = function() return 0 end,
    rt_unhook_all = function() return 0 end,
    rt_stats = function() return 4, 0xD8, 0, 0 end,
    rt_read_ptr = function() return nil end,
})
UE.beginFrame()
if sent then upHook(rpcGuestPC, sent.loc, sent.rot) end
Chan.pump()
check("the host answers the talk with the guest's choice", hostClicks[1] == 2, tostring(hostClicks[1]))

-- The talk ends on the host: the guest's dialog closes and the mouse goes back.
if H.hooks[ENDFN] then H.hooks[ENDFN](talk) end
before = #sentStrings
UE.beginFrame()
TalkSync.tickHost(101.5)
local endMsg = sentStrings[#sentStrings]
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, endMsg or "")
Chan.pump()
check("when it ends on the host it closes on the guest, input back to the game",
      #sentStrings > before and guestWidget and guestWidget.inVp == false and calls[#calls] == "game input"
      and not TalkSync.guestTalking(), tostring(endMsg))
upBefore = #upSends
GuestInput5._onPress(1)
check("and the guest's clicks go to the host again", #upSends > upBefore, ("%d sent"):format(#upSends - upBefore))
hostPC.Pawn, hostPC.PlayerCameraManager = savedLocalPawn, savedCam

-- A guest who leaves mid-conversation: the talk is quit on the host, so the
-- staff member is not left waiting for an answer that never comes - but only
-- while the host is just walking (ending a talk resets player 0's controls).
H.theWorld.NetDriver.ServerConnection = nil
hostWidget.inVp = true
UE.beginFrame()
if H.hooks[BEGIN] then H.hooks[BEGIN](talk) end
rpcGuestPC.__dead = true
local clicksBefore = #hostClicks
hostPC["Walking Mapping Context is Enable"], hostPC.bShowMouseCursor = false, true   -- at the register
UE.beginFrame()
TalkSync.tickHost(103)
check("a departed guest's conversation waits while the host is at the register", #hostClicks == clicksBefore,
      ("%d click(s)"):format(#hostClicks - clicksBefore))
hostPC["Walking Mapping Context is Enable"], hostPC.bShowMouseCursor = true, false
UE.beginFrame()
TalkSync.tickHost(104)
rpcGuestPC.__dead = nil
hostPC["Walking Mapping Context is Enable"] = nil
check("and is quit once the host is walking", hostClicks[#hostClicks] == 1 and #hostClicks == clicksBefore + 1,
      tostring(hostClicks[#hostClicks]))

-- The guest's side: a conversation the host stopped saying closes by itself.
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, talkMsg or "")
Chan.pump()
local reopened = TalkSync.guestTalking()
TalkSync._ageGuest(30)
TalkSync.tickGuest()
check("a guest's conversation the host has gone quiet about closes, input back to the game",
      reopened and not TalkSync.guestTalking() and calls[#calls] == "game input",
      ("open %s, then %s"):format(tostring(reopened), tostring(TalkSync.guestTalking())))
H.theWorld.NetDriver.ServerConnection = nil
hostPC.bShowMouseCursor = nil

H.theWorld.NetDriver.ServerConnection = nil
rpcGuestPC.Pawn = savedGuestPawn
for _, cls in ipairs({ "TalkSystem_C", "Player_Character_C" }) do
    for i, o in ipairs(H.world.objects[cls] or {}) do
        if o == talk or o == guestPawnOnHost then table.remove(H.world.objects[cls], i) break end
    end
end
for _, k in ipairs({ BEGIN, ENDFN, TALK_UI, ANSWER_UI, ANSWER_FN, "/Script/UMG.Default__WidgetBlueprintLibrary",
                     "/Script/Engine.Default__KismetSystemLibrary" }) do
    H.staticObjects[k] = nil
end
hostPC.bShowMouseCursor = nil
Native._fake(nil)
TalkSync.reset()
GuestInput5.reset()
UE._resetLookups()
UE.beginFrame()
end

-- --------------------------------------------------------------- verdict --

print("")
if #failures > 0 then
    print(("%d CHECK(S) FAILED:"):format(#failures))
    for _, f in ipairs(failures) do print("   " .. f) end
    os.exit(1)
end
print("All checks passed.")

