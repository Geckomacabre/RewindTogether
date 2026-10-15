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

-- A member of staff to copy from, and another player with an empty mesh.
H.spawn("Staff_C", { Mesh = meshComponent(
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
check("says where the body came from", logHas("borrowed from Staff_C"), "not logged")

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
H.theWorld.NetDriver.ServerConnection = H.obj("NetConnection", { __isActor = false })
UE.beginFrame()
H.hooks["/Script/Engine.PlayerController:ClientMessage"](rpcGuestPC, worldWire)
Chan.pump()
H.theWorld.NetDriver.ServerConnection = nil
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

-- ------------------------------------------------- 7. crash breadcrumbs --

print("\n-- crash breadcrumbs --")
os.remove("RewindTogether-disabled.txt")
os.remove("RewindTogether-inprogress.txt")

local S = require("safety")
S.reset()

local ran, result = S.guard("pretend-risky", function() return "done" end)
check("guard runs and returns", ran and result == "done", tostring(result))

local fh = io.open("RewindTogether-inprogress.txt", "r")
check("breadcrumb is cleaned up on success", fh == nil)
if fh then fh:close() end

-- Simulate a crash: a breadcrumb left behind by a process that never returned.
-- Reset FIRST, because reset deliberately clears breadcrumbs too.
S.reset()
local w = io.open("RewindTogether-inprogress.txt", "w")
w:write("pretend-risky\n"); w:close()
local crashed = S.init()
check("detects what crashed",    crashed == "pretend-risky", tostring(crashed))
check("blocks it afterwards",    S.isBlocked("pretend-risky"))

local ran2 = S.guard("pretend-risky", function() error("should never run") end)
check("blocked operation does not run", ran2 == false)

S.reset()
check("reset clears the block", not S.isBlocked("pretend-risky"))
os.remove("RewindTogether-disabled.txt")
os.remove("RewindTogether-inprogress.txt")

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
check("the host patches an actor its class default did not reach",
      fresh.bReplicateMovement == true and setRep == 1, tostring(fresh.bReplicateMovement))
check("bReplicateMovement never goes on a class default, so guests are sent it",
      tapeCls.__cdo.bReplicates == true and tapeCls.__cdo.bReplicateMovement == nil,
      tostring(tapeCls.__cdo.bReplicateMovement))
UE.endFrame() UE.beginFrame()
Rep.sweep()
check("a patched actor is left alone after that", setRep == 1, ("%d patches"):format(setRep))

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

-- --------------------------------------------------------------- verdict --

print("")
if #failures > 0 then
    print(("%d CHECK(S) FAILED:"):format(#failures))
    for _, f in ipairs(failures) do print("   " .. f) end
    os.exit(1)
end
print("All checks passed.")

