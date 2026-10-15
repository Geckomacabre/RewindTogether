--[[
    Rewind Together - guest pawn provisioning

    THE PROBLEM THIS SOLVES

    A guest connects, the host logs the arrival ("a player joined (2
    connected)"), and then the guest sits at a black screen forever. Nothing
    errors, nothing is logged, the connection is genuinely up. They simply have
    no pawn, and a PlayerController with no pawn and no view target renders the
    world from the origin - which in this store is inside solid geometry, i.e.
    black.

    Why it happens: hosting turns a single-player game into a listen server,
    but AGameModeBase's login path has never once run for a second player in
    this game's life. PostLogin -> HandleStartingNewPlayer -> RestartPlayer ->
    SpawnDefaultPawnFor(FindPlayerStart) is a chain of four steps, and a
    single-player GameMode only has to satisfy the ones its own startup uses.
    Any of these breaks it, and all of them look identical from outside:

      * DefaultPawnClass is not the store character (the game creates and
        possesses Player_Character_C itself, from its own Blueprint logic, for
        player 0 only),
      * the level contains no APlayerStart, so FindPlayerStart returns null
        and RestartPlayer quietly gives up,
      * a Blueprint override of HandleStartingNewPlayer does the game's own
        thing and never calls RestartPlayer,
      * bStartPlayersAsSpectators / bDelayedStart are set, which suppress the
        restart by design.

    So this module does not guess which one it is. It watches for a remote
    controller that has no pawn, gives the game's own login path first refusal,
    and then walks an escalating ladder of increasingly blunt routes until the
    controller is driving something - logging which rung worked, so the next
    person to read the log knows what this build actually needed.

    Everything here runs on the host. Spawning and possession are
    authority-only operations; a guest cannot fix this for themselves, which is
    why the guest side of this file only diagnoses and explains.

    The no-actor-pointers rule from replication.lua applies here too: this
    module keys its bookkeeping on controller names and re-resolves every
    object each poll, so nothing it holds can go stale or be freed underneath
    it between frames.
]]

local Log    = require("log")
local UE     = require("ue")
local Replication = require("replication")
local Safety = require("safety")

local Spawn = {}

local cfg = nil

-- controller full name -> { since, attempts, lastTry, gaveUp }
local watch      = {}
local lastPoll   = 0
local diagnosed  = false
local forcedUntil = 0        -- rt.fixpawns overrides the config switch until this time
local clientWarned = false
local clientPawnlessSince = nil

local POLL_INTERVAL  = 1.0
local GRACE          = 4.0   -- let the game's own login path try first
local RETRY_INTERVAL = 3.0   -- a route may need a frame or two to take effect
local CLIENT_PATIENCE= 12.0  -- before telling the guest what is wrong

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function shortName(fullName)
    return (tostring(fullName):match("([^%.:]+)$") or tostring(fullName))
end

local function nameOf(obj)
    if not UE.valid(obj) then return "<none>" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and shortName(n) or UE.ClassNameOf(obj)
end

local function locationOf(actor)
    if not UE.valid(actor) then return nil end
    local l = nil
    pcall(function() l = actor:K2_GetActorLocation() end)
    if l == nil or l.X == nil then return nil end
    return { X = l.X, Y = l.Y, Z = l.Z }
end

local function locStr(actor)
    local l = locationOf(actor)
    if not l then return "?" end
    return ("(%.0f, %.0f, %.0f)"):format(l.X, l.Y, l.Z)
end

local isLocalController = UE.IsLocalController

--- Is this a guest who is still here, or one the engine is already unwinding?
---
--- THIS IS THE GUARD THE LADDER WAS MISSING, and the most likely cause of the
--- one crash this file has produced. A departing player's controller does not
--- vanish on the frame they leave: the engine drops their UNetConnection,
--- flags the actor as garbage, and FindAllOf keeps returning it for a while
--- afterwards. During that window it presents exactly like somebody who needs
--- a body - no pawn, because theirs was just unpossessed and left standing in
--- the store - so the ladder happily picked it up and called a GameMode login
--- function with a controller that was being freed underneath it.
---
--- The log records it: the guest showed "pawn: NONE" alongside "1 possessed,
--- 1 unpossessed", four seconds later route 1 fired, and the next line is a
--- new session. Nothing was logged by either side, which is the signature of
--- a native access violation rather than a Lua error.
---
--- UNetConnection derives from UPlayer, so a genuinely connected remote
--- controller has a Player and one whose connection has been cleaned up does
--- not. Combined with the garbage check in UE.alive that separates the two
--- cases the ladder must never confuse.
local function isLiveGuest(pc)
    if not UE.alive(pc) then return false end
    if isLocalController(pc) then return false end
    if not UE.alive(UE.TryGet(pc, "Player")) then return false end
    return true
end

local function classNameOfProperty(obj, prop)
    local cls = UE.TryGet(obj, prop)
    if not UE.valid(cls) then return "<none>" end
    local ok, n = pcall(function() return cls:GetFName():ToString() end)
    return ok and n or "<unreadable>"
end

--- Report a flag the way a flag should read.
---
--- UE4SS does not return nil for a property the class does not have - it hands
--- back some other object - so a missing bool printed as
--- "bDelayedStart: UObject: 000001305A930268", which reads like a value and is
--- not one. bDelayedStart lives on AGameMode, and this game's GameMode derives
--- from AGameModeBase, so it is genuinely absent rather than merely unreadable.
local function boolProperty(obj, prop)
    local v = UE.TryGet(obj, prop)
    if type(v) == "boolean" then return tostring(v) end
    if v == nil then return "<not on this class>" end
    return "<not a bool - this class does not have it>"
end

--- The class the store's player character actually is.
---
--- Taken from the pawn the host is driving wherever possible: that is correct
--- by construction and cannot go stale if the game moves its assets in a
--- patch. The hard-coded path is only a fallback.
local function playerPawnClass()
    local hostPawn = UE.GetPawn()
    if UE.valid(hostPawn) and UE.ClassNameOf(hostPawn):find("Player_Character") then
        local cls = nil
        pcall(function() cls = hostPawn:GetClass() end)
        if UE.valid(cls) then return cls end
    end

    local cls = StaticFindObject(UE.Paths.PlayerCharacter)
    if UE.valid(cls) then return cls end

    local all = UE.findAll("Player_Character_C")
    if all then
        for _, p in ipairs(all) do
            if UE.valid(p) then
                local c = nil
                pcall(function() c = p:GetClass() end)
                if UE.valid(c) then return c end
            end
        end
    end
    return nil
end

--- Where to put a new arrival: a PlayerStart if the level has one, otherwise
--- just beside the host. Returns location, rotation, description.
local function spawnPoint()
    local ps = UE.findFirst("PlayerStart")
    if UE.valid(ps) then
        local loc, rot
        local ok = pcall(function()
            loc = ps:K2_GetActorLocation()
            rot = ps:K2_GetActorRotation()
        end)
        if ok and loc then
            return { X = loc.X, Y = loc.Y, Z = loc.Z + 20.0 },
                   rot or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
                   "a PlayerStart"
        end
    end

    -- Beside the host, not on top of them: two capsules spawned inside each
    -- other resolve by shoving one of them through the floor.
    local hp = UE.GetPawn()
    if UE.valid(hp) then
        local loc, rot
        local ok = pcall(function()
            loc = hp:K2_GetActorLocation()
            rot = hp:K2_GetActorRotation()
        end)
        if ok and loc then
            return { X = loc.X + 150.0, Y = loc.Y + 150.0, Z = loc.Z + 30.0 },
                   rot or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
                   "next to the host"
        end
    end

    return nil, nil, nil
end

local function yawQuat(rot)
    rot = UE.rot(rot)
    local h = math.rad((rot and rot.Yaw) or 0.0) * 0.5
    return { X = 0.0, Y = 0.0, Z = math.sin(h), W = math.cos(h) }
end

local function transformAt(loc, rot)
    return {
        Rotation    = yawQuat(rot),
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D     = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
end

--- Hand a pawn to a controller and make sure the client looks through it.
local function possess(pc, pawn)
    if not (UE.valid(pc) and UE.valid(pawn)) then return false end

    local ok = pcall(function() pc:Possess(pawn) end)
    if not ok then
        Log.warn("AController::Possess is not callable on this build")
        return false
    end

    -- Possession alone is not enough to end a black screen. The camera follows
    -- the view target, and a controller that was never restarted does not have
    -- one, so it renders from the world origin. SetViewTargetWithBlend is
    -- replicated to the owning client, so doing it here fixes it there.
    pcall(function() pc:SetViewTargetWithBlend(pawn, 0.0, 0, 0.0, false) end)
    return true
end

--------------------------------------------------------------------------
-- The ladder
--------------------------------------------------------------------------
-- Each route dispatches an attempt and returns whether it got that far. None
-- of them claim success: whether the controller actually ended up with a pawn
-- is decided by the next poll, which is the only honest test.

--- 1. The game's own login path, exactly as the engine would have run it.
--- If the game has a Blueprint override that works, this is the rung that
--- keeps its behaviour intact, so it is tried first.
local function routeHandleStartingNewPlayer(gm, pc)
    if not UE.valid(gm) then return false end
    Spawn.reentrant = true
    local ok = pcall(function() gm:HandleStartingNewPlayer(pc) end)
    Spawn.reentrant = false
    return ok
end

--- Somewhere to put an arriving player, as an ACTOR rather than a transform.
---
--- SpawnDefaultPawnFor takes an AActor* and only ever reads its location and
--- yaw, so any actor will do - and passing one costs nothing but an object
--- reference. That matters more than it looks: building an FTransform means
--- handing UE4SS a nested Lua table for a struct containing a quaternion, and
--- whether that marshals correctly is a property of the UE4SS build rather
--- than of this game. Every rung that can avoid needing it, does.
local function findStartSpot(gm, pc)
    local start = nil
    if UE.valid(gm) then
        pcall(function() start = gm:K2_FindPlayerStart(pc, "") end)
        if not UE.valid(start) then
            pcall(function() start = gm:ChoosePlayerStart(pc) end)
        end
    end
    if not UE.valid(start) then start = UE.findFirst("PlayerStart") end
    if UE.valid(start) then return start, "a PlayerStart" end

    -- No PlayerStart in the level. Standing them on the host is not elegant,
    -- but the spawn's collision handling pushes the capsules apart, and being
    -- briefly inside somebody beats being nowhere at all.
    local hostPawn = UE.GetPawn()
    if UE.valid(hostPawn) then return hostPawn, "where the host is standing" end

    return nil, nil
end

--- 2. The engine's own spawn-and-possess, skipping whatever the game put in
--- front of it.
local function routeSpawnDefaultPawnFor(gm, pc)
    if not UE.valid(gm) then return false end

    local start, where = findStartSpot(gm, pc)
    -- Never call this with no start spot. The engine's own implementation
    -- handles null, but a Blueprint override is free to dereference it.
    if not UE.valid(start) then
        Log.info("  nowhere to spawn them - no PlayerStart and no host pawn")
        return false
    end

    local pawn = nil
    pcall(function() pawn = gm:SpawnDefaultPawnFor(pc, start) end)
    if not UE.valid(pawn) then
        Log.info("  SpawnDefaultPawnFor produced nothing (DefaultPawnClass is %s)",
                 classNameOfProperty(gm, "DefaultPawnClass"))
        return false
    end
    Log.info("  spawned %s at %s", UE.ClassNameOf(pawn), where)
    return possess(pc, pawn)
end

--- 3. The same call, but with the GameMode temporarily told to make the
--- store's character.
---
--- This is the rung that covers the likeliest cause of all: a GameMode whose
--- DefaultPawnClass was never pointed at anything useful, because this game
--- builds its player from its own Blueprint and has never once needed the
--- engine to do it. Route 2 then dutifully spawns whatever placeholder is
--- configured - often nothing, sometimes a bare DefaultPawn.
---
--- Borrowing the property for one call keeps everything else on the engine's
--- own path: ownership, instigator, collision handling and possession all
--- behave exactly as they would for a normal game. The old value goes back
--- immediately, whatever happened, so nothing outlives this function.
local function routeForceDefaultPawnClass(gm, pc)
    if not UE.valid(gm) then return false end

    local cls = playerPawnClass()
    if not UE.valid(cls) then
        Log.info("  could not resolve the Player_Character class")
        return false
    end

    local start, where = findStartSpot(gm, pc)
    if not UE.valid(start) then
        Log.info("  nowhere to spawn them")
        return false
    end

    local previous = UE.TryGet(gm, "DefaultPawnClass")
    if not UE.TrySet(gm, "DefaultPawnClass", cls) then
        Log.info("  DefaultPawnClass is not writable on this build")
        return false
    end

    local pawn = nil
    pcall(function() pawn = gm:SpawnDefaultPawnFor(pc, start) end)

    if UE.valid(previous) then UE.TrySet(gm, "DefaultPawnClass", previous) end

    if not UE.valid(pawn) then
        Log.info("  still nothing, even with DefaultPawnClass forced")
        return false
    end
    Log.info("  spawned %s at %s", UE.ClassNameOf(pawn), where)
    return possess(pc, pawn)
end

--- 4. Build the store's own character ourselves and hand it over.
---
--- Last rung that can create anything, and the only one that needs an
--- FTransform - which is why it is this far down rather than first.
local function routeSpawnPlayerCharacter(_, pc)
    local gs  = UE.GetGameplayStatics()
    local w   = UE.GetWorld()
    local cls = playerPawnClass()

    if not UE.valid(cls) then
        Log.info("  could not resolve the Player_Character class")
        return false
    end
    if not (UE.valid(gs) and UE.valid(w)) then return false end

    local loc, rot, where = spawnPoint()
    if not loc then
        Log.info("  no spawn point could be worked out")
        return false
    end

    local xform = transformAt(loc, rot)
    local actor = nil

    -- AdjustIfPossibleButAlwaysSpawn (2): we would rather nudge the guest out
    -- of a shelf than refuse to give them a body.
    pcall(function()
        actor = gs:BeginDeferredActorSpawnFromClass(w, cls, xform, 2, nil, 0)
    end)
    if not UE.valid(actor) then
        -- Older signatures take fewer arguments; try the short form before
        -- concluding the route is unavailable.
        pcall(function()
            actor = gs:BeginDeferredActorSpawnFromClass(w, cls, xform, 2, nil)
        end)
    end
    if not UE.valid(actor) then
        Log.info("  deferred spawn was refused")
        return false
    end

    pcall(function() gs:FinishSpawningActor(actor, xform, 0) end)
    if not UE.valid(actor) then
        Log.info("  the spawned actor did not survive FinishSpawningActor")
        return false
    end

    Log.info("  built a %s at %s", UE.ClassNameOf(actor), where)
    return possess(pc, actor)
end

--- 5. Last resort: an unpossessed store character is already standing there.
---
--- Guarded hard. Possessing a pawn that somebody is already driving would take
--- the host's body away from them, which is a far worse failure than the one
--- being fixed, so anything with a controller is left strictly alone.
local function routeAdoptOrphanPawn(_, pc)
    local all = UE.findAll("Player_Character_C")
    if not all then return false end

    for _, pawn in ipairs(all) do
        if UE.valid(pawn) then
            local controller = UE.TryGet(pawn, "Controller")
            local owner      = UE.TryGet(pawn, "Owner")
            if not UE.valid(controller) and not UE.valid(owner) then
                Log.info("  adopting unpossessed pawn %s", nameOf(pawn))
                return possess(pc, pawn)
            end
        end
    end

    Log.info("  no unpossessed Player_Character_C to adopt")
    return false
end

--------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------
--[[
    Having a pawn is not the same as being anywhere sensible.

    On this build the engine's login path works: the GameMode's
    DefaultPawnClass really is Player_Character_C, and the level really does
    contain a PlayerStart, so an arriving guest is given a proper character
    without the ladder above ever running. They are then dropped at that
    PlayerStart - and there is exactly one, in a game that has never used it.
    Retro Rewind puts YOU in your store from your save file, not from a spawn
    marker, so nothing has ever had to be correct about where that marker sits.
    A guest can therefore end up under the floor, outside the building, or at
    the origin.

    Two things are done about it, and they are separate problems that produce
    the same complaint ("I spawned under the map"):

      * POSITION. The guest is moved next to the host shortly after they
        arrive. This is also just better co-op behaviour than a fixed spawn
        marker - you appear where your friend is.

      * VIEW TARGET. If a controller was never properly restarted its camera
        has no view target and renders from the world origin, which in a store
        built away from the origin looks exactly like being under the map even
        though the pawn is standing in the right place. Setting it costs
        nothing and rules the whole class of problem out.

    The rescue loop that follows exists because a one-off nudge does not help
    if the guest is falling: if their Z keeps ending up far below the host's,
    they are dropping through geometry rather than sitting in the wrong spot,
    and that is worth saying out loud rather than teleporting forever.
]]

local placed = {}       -- controller full name -> { at, rescues, lastRescue }

local PLACE_DELAY    = 1.5    -- let the game finish its own arrival work first
local FALL_MARGIN    = 400.0  -- units below the host before we call it falling
local RESCUE_EVERY   = 3.0
local MAX_RESCUES    = 4
-- A pawn older than this when this module first sees it is not an arrival.
-- A real arrival is seen within a second or two of its pawn being made (the
-- login path makes it; the poll is 1 s), so this has a wide margin.
local ARRIVAL_WINDOW = 10.0

--- Somewhere to stand near the host. `slot` spreads multiple guests around a
--- ring so two arrivals do not resolve their overlap by pushing each other
--- through the floor.
local function spotNearHost(slot)
    local hostPawn = UE.GetPawn()
    local base = locationOf(hostPawn)
    if not base then return nil, nil end

    local angle = (math.pi * 2.0 / 4.0) * ((slot or 0) % 4)
    local radius = 160.0
    local rot = nil
    pcall(function() rot = hostPawn:K2_GetActorRotation() end)

    return {
        X = base.X + math.cos(angle) * radius,
        Y = base.Y + math.sin(angle) * radius,
        Z = base.Z + 40.0,
    }, rot or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
end

--- How long ago this pawn was made, in game seconds, or nil.
local function ageOf(pawn)
    local ok, t = pcall(function() return pawn:GetGameTimeSinceCreation() end)
    return ok and type(t) == "number" and t or nil
end

--- Can this pawn be teleported without falling through the world? Not with
--- its collision off or its movement switched off (MOVE_None): that is a
--- guest at the till (guestinput.lua), and the one time a guest was moved
--- like that it fell out of the store, out of network range and back - and
--- crashed. Returns true, or false and why not. Fails open when the pawn
--- cannot be asked, as every check here that would strand somebody does.
local function canMove(pawn)
    local okC, collides = pcall(function() return pawn:GetActorEnableCollision() end)
    if okC and collides == false then return false, "its collision is off" end
    local move = UE.TryGet(pawn, "CharacterMovement")
    local mode = UE.valid(move) and UE.TryGet(move, "MovementMode") or nil
    if mode == 0 then return false, "its movement is switched off" end
    return true
end

--- Move a pawn, preferring the call that respects collision.
local function moveTo(pawn, loc, rot)
    if not (UE.valid(pawn) and loc) then return false end
    -- A guest's position is theirs (replication.lua trusts it): without this
    -- the guest is never told, and the host takes their old spot back.
    Replication.beforeHostMovesGuest(pawn)

    local ok, moved = pcall(function()
        return pawn:K2_TeleportTo(loc, rot or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    end)
    if ok and moved ~= false then return true end

    -- TeleportTo refuses if the destination is blocked. Placing them anyway
    -- beats leaving them under the world; bTeleport = true so the movement
    -- component sends a correction rather than interpolating them across the
    -- level.
    ok = pcall(function()
        UE.withHit(function(hit) pawn:K2_SetActorLocation(loc, false, hit, true) end)
    end)
    return ok
end

--- Make sure the owning client is actually looking through its pawn.
local function ensureViewTarget(pc, pawn)
    if not (UE.valid(pc) and UE.valid(pawn)) then return end
    pcall(function() pc:SetViewTargetWithBlend(pawn, 0.0, 0, 0.0, false) end)
end

--- Put one guest beside the host. Returns true if anything was done.
function Spawn.placeGuest(pc, pawn, slot, why)
    if not (UE.valid(pc) and UE.valid(pawn)) then return false end

    local movable, whyNot = canMove(pawn)
    if not movable then
        Log.info("not moving %s: %s (at the till?) - teleporting it would drop it " ..
                 "through the floor", nameOf(pc), whyNot)
        ensureViewTarget(pc, pawn)
        return false
    end

    local loc, rot = spotNearHost(slot)
    if not loc then
        Log.warn("cannot place a guest: the host has no pawn to stand next to")
        return false
    end

    local before = locStr(pawn)
    local ok = moveTo(pawn, loc, rot)
    ensureViewTarget(pc, pawn)

    Log.info("%s %s: %s -> %s", why or "placed", nameOf(pc), before, locStr(pawn))
    return ok
end

--- Move every connected guest to the host. Wired to rt.bring.
function Spawn.bringEveryone()
    local n = 0
    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        if isLiveGuest(pc) then
            local pawn = UE.TryGet(pc, "Pawn")
            if UE.valid(pawn) then
                if Spawn.placeGuest(pc, pawn, n, "brought") then n = n + 1 end
            end
        end
    end
    return n
end

--- Called once per poll for a guest that already has a pawn.
local function tendPlacedGuest(now, key, pc, pawn, slot)
    local entry = placed[key]

    if not entry then
        entry = { seen = now, at = nil, rescues = 0, lastRescue = 0 }
        placed[key] = entry
        -- A pawn that has been around for a while is not arriving: this
        -- module has been reloaded underneath a session (a UE4SS hot reload
        -- forgets everything here) and the guest is already somewhere they
        -- chose. Measured in 1.7.0: the host's reload put a guest who was at
        -- the till beside the host, collision off, and they fell out of the
        -- world. Placing is for arrivals only; the falling rescue still runs.
        local age = ageOf(pawn)
        if age and age > ARRIVAL_WINDOW then
            entry.at = now
            Log.info("%s already has a character in the store (made %.0fs ago) - leaving " ..
                     "them where they are", nameOf(pc), age)
            ensureViewTarget(pc, pawn)
        end
        return
    end

    -- First placement, once the game has had a moment to finish arrival.
    if not entry.at then
        if (now - entry.seen) < PLACE_DELAY then return end
        entry.at = now
        if cfg and cfg.PlaceGuestsNextToHost ~= false then
            Spawn.placeGuest(pc, pawn, slot, "placed")
        else
            -- Even with placement off, a camera with no view target is never
            -- what anyone wants.
            ensureViewTarget(pc, pawn)
        end
        return
    end

    -- Rescue: are they falling out of the world?
    if not cfg or cfg.RescueFallingGuests == false then return end
    if entry.rescues >= MAX_RESCUES then return end
    if (now - entry.lastRescue) < RESCUE_EVERY then return end

    local guestLoc = locationOf(pawn)
    local hostLoc  = locationOf(UE.GetPawn())
    if not (guestLoc and hostLoc) then return end

    if guestLoc.Z < (hostLoc.Z - FALL_MARGIN) then
        entry.rescues    = entry.rescues + 1
        entry.lastRescue = now
        Log.warn("%s is %.0f units below the host - pulling them back (%d/%d)",
                 nameOf(pc), hostLoc.Z - guestLoc.Z, entry.rescues, MAX_RESCUES)
        Spawn.placeGuest(pc, pawn, slot, "rescued")

        if entry.rescues >= MAX_RESCUES then
            Log.error("=====================================================")
            Log.error(" %s keeps falling through the floor.", nameOf(pc))
            Log.error("")
            Log.error(" Being moved back %d times means this is not a bad", MAX_RESCUES)
            Log.error(" spawn point - the floor they are standing on does")
            Log.error(" not exist on their machine. Not retrying; run")
            Log.error(" rt.bring to pull them up again by hand.")
            Log.error("=====================================================")
        end
    end
end

local ROUTES = {
    { name = "the game's own login path (HandleStartingNewPlayer)", fn = routeHandleStartingNewPlayer },
    { name = "SpawnDefaultPawnFor",                                 fn = routeSpawnDefaultPawnFor },
    { name = "SpawnDefaultPawnFor with DefaultPawnClass forced",    fn = routeForceDefaultPawnClass },
    { name = "spawning Player_Character_C directly",                fn = routeSpawnPlayerCharacter },
    { name = "adopting an unpossessed character",                   fn = routeAdoptOrphanPawn },
}

--------------------------------------------------------------------------
-- Diagnosis
--------------------------------------------------------------------------

--- Everything worth knowing about why a player does or does not have a body.
--- Returned as lines so both the log and the console command can use it.
function Spawn.reportLines()
    local lines = {}
    local function add(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and s or tostring(fmt)
    end

    add("mode: %s", UE.NetModeName())

    local gm = UE.GetGameMode()
    if UE.valid(gm) then
        add("GameMode: %s", UE.ClassNameOf(gm))
        add("  DefaultPawnClass:         %s", classNameOfProperty(gm, "DefaultPawnClass"))
        add("  PlayerControllerClass:    %s", classNameOfProperty(gm, "PlayerControllerClass"))
        add("  bStartPlayersAsSpectators: %s", boolProperty(gm, "bStartPlayersAsSpectators"))
        add("  bDelayedStart:            %s", boolProperty(gm, "bDelayedStart"))
    else
        add("GameMode: <not resolvable> (normal on a guest - only the host has one)")
    end

    local starts = UE.findAll("PlayerStart")
    local nStarts = 0
    if starts then
        for _, s in ipairs(starts) do
            if UE.valid(s) then
                nStarts = nStarts + 1
                if nStarts <= 3 then add("PlayerStart at %s", locStr(s)) end
            end
        end
    end
    add("PlayerStart actors in this level: %d%s", nStarts,
        nStarts == 0 and "   <- the engine's spawn path cannot work without one" or "")

    -- Coordinates are the whole point of this report now that pawns arrive on
    -- their own: "has a pawn" and "is somewhere you can see the shop from" are
    -- different questions, and only the numbers tell them apart.
    local hostZ = nil
    local hostPawn = UE.GetPawn()
    if UE.valid(hostPawn) then
        local l = locationOf(hostPawn)
        if l then hostZ = l.Z end
    end

    add("players:")
    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        local pawn = UE.TryGet(pc, "Pawn")
        local who  = UE.PlayerNameOf(pc) or "?"

        local note = ""
        if not UE.alive(pc) then
            note = "   <- LEAVING (controller is being destroyed)"
        elseif not isLocalController(pc) and not UE.alive(UE.TryGet(pc, "Player")) then
            note = "   <- LEAVING (connection already cleaned up)"
        end
        -- A controller that is leaving outranks where its pawn is standing.
        if note == "" and UE.valid(pawn) and hostZ then
            local l = locationOf(pawn)
            if l and l.Z < (hostZ - FALL_MARGIN) then
                note = ("   <- %.0f units BELOW the host"):format(hostZ - l.Z)
            end
        end

        add("  %-28s %-8s %-14s pawn: %s at %s%s",
            nameOf(pc),
            isLocalController(pc) and "local" or "remote",
            who,
            UE.valid(pawn) and UE.ClassNameOf(pawn) or "NONE  <- black screen",
            locStr(pawn),
            note)
    end

    local pawns = UE.findAll("Player_Character_C")
    if pawns then
        local free, taken = 0, 0
        for _, p in ipairs(pawns) do
            if UE.valid(p) then
                if UE.valid(UE.TryGet(p, "Controller")) then taken = taken + 1 else free = free + 1 end
            end
        end
        add("Player_Character_C in world: %d possessed, %d unpossessed", taken, free)
    end

    return lines
end

local function logReport()
    Log.info("---- pawn diagnosis ----")
    for _, line in ipairs(Spawn.reportLines()) do Log.info("  %s", line) end
    Log.info("------------------------")
end
Spawn.logReport = logReport

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Spawn.init(config)
    cfg = config
end

--- Called when a session starts. Clears the two GameMode flags that silently
--- suppress a restart, then forgets any state from a previous session.
function Spawn.onSessionStart()
    watch, placed, diagnosed = {}, {}, false
    clientWarned, clientPawnlessSince = false, nil
    if not UE.IsHosting() then return end

    local gm = UE.GetGameMode()
    if not UE.valid(gm) then return end

    -- Neither flag has ever been exercised in this game, so whatever they are
    -- set to is untested rather than deliberate. Both stop a joining player
    -- from being given a pawn.
    if UE.TryGet(gm, "bStartPlayersAsSpectators") == true then
        if UE.TrySet(gm, "bStartPlayersAsSpectators", false) then
            Log.info("GameMode had bStartPlayersAsSpectators set - cleared it")
        end
    end
    if UE.TryGet(gm, "bDelayedStart") == true then
        if UE.TrySet(gm, "bDelayedStart", false) then
            Log.info("GameMode had bDelayedStart set - cleared it")
        end
    end
end

--- Force the ladder to run again from the top for everyone who needs it.
--- Wired to rt.fixpawns, for when a guest is staring at black right now.
---
--- Seeds the watch list from the live controllers rather than only resetting
--- what is already in it, so this works even if the automatic watcher was
--- switched off or has not noticed the guest yet - which is exactly the state
--- somebody is in when they reach for this command.
function Spawn.retryNow()
    local n = 0
    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        if isLiveGuest(pc) and not UE.valid(UE.TryGet(pc, "Pawn")) then
            local key = nil
            pcall(function() key = pc:GetFullName() end)
            if key then
                watch[key] = { since = 0, attempts = 0, lastTry = 0 }
                n = n + 1
            end
        end
    end
    for _, entry in pairs(watch) do
        entry.attempts, entry.gaveUp, entry.lastTry, entry.since = 0, false, 0, 0
    end

    -- An explicit request outranks the config switch; honour it for long
    -- enough to walk the whole ladder.
    forcedUntil = os.clock() + 60.0
    lastPoll    = 0
    diagnosed   = false
    return n
end

--------------------------------------------------------------------------
-- Host tick
--------------------------------------------------------------------------

function Spawn.tickHost(now)
    -- Compared against false, not falsy: a config.lua predating this option
    -- has no such field, and the fix must not be off just because someone is
    -- carrying an older file forward.
    if not cfg then return end
    if cfg.AutoSpawnGuestPawns == false and now > forcedUntil then return end
    if not UE.IsHosting() then return end
    if (now - lastPoll) < POLL_INTERVAL then return end
    lastPoll = now

    -- Belt and braces: if a route ever dies between raising this flag and
    -- lowering it, the join announcement would stay suppressed for the rest of
    -- the session. It is only meant to span a single call.
    Spawn.reentrant = false

    local gm     = UE.GetGameMode()
    local seen   = {}
    local guests = 0

    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        local key = nil
        pcall(function() key = pc:GetFullName() end)

        if key then
            seen[key] = true
            local pawn  = UE.TryGet(pc, "Pawn")
            local entry = watch[key]

            if UE.valid(pawn) then
                if entry and entry.attempts > 0 then
                    Log.info("%s is driving a %s - fixed by %s",
                             shortName(key), UE.ClassNameOf(pawn),
                             ROUTES[entry.attempts] and ROUTES[entry.attempts].name or "?")
                end
                watch[key] = nil

                -- Having a pawn is only half of it: they still have to be
                -- standing somewhere real, and looking through it. Teleporting
                -- somebody whose connection is already being cleaned up is at
                -- best pointless and at worst the same crash as below.
                if isLiveGuest(pc) then
                    guests = guests + 1
                    tendPlacedGuest(now, key, pc, pawn, guests - 1)
                end

            elseif isLiveGuest(pc) then
                -- A guest with no pawn. The host's own controller is left
                -- alone: it is briefly pawnless during travel and the game's
                -- single-player path handles it correctly, so stepping in
                -- there could only ever make things worse.
                if not entry then
                    watch[key] = { since = now, attempts = 0, lastTry = 0 }
                    Log.info("%s has no pawn - giving the game's own login path %.0fs",
                             shortName(key), GRACE)

                elseif (now - entry.since) > GRACE
                   and (now - entry.lastTry) > RETRY_INTERVAL
                   and not entry.gaveUp then

                    if not diagnosed then
                        diagnosed = true
                        logReport()
                    end

                    if entry.attempts >= #ROUTES then
                        entry.gaveUp = true
                        Log.error("=====================================================")
                        Log.error(" Could not give %s a pawn.", shortName(key))
                        Log.error("")
                        Log.error(" They are connected, but every route to a body was")
                        Log.error(" refused, so they will stay on a black screen. The")
                        Log.error(" diagnosis above says which pieces this build has.")
                        Log.error("")
                        Log.error(" Run  rt.pawns    to print that again, or")
                        Log.error("     rt.fixpawns  to try the whole ladder once more.")
                        Log.error("=====================================================")
                    else
                        entry.attempts = entry.attempts + 1
                        entry.lastTry  = now
                        local route = ROUTES[entry.attempts]
                        Log.info("giving %s a pawn - attempt %d/%d: %s",
                                 shortName(key), entry.attempts, #ROUTES, route.name)
                        -- Behind a breadcrumb: this ladder has taken the game
                        -- down once already. If a rung does it again, the next
                        -- launch retires that rung rather than repeating it,
                        -- and the remaining four still get their chance.
                        local ran = Safety.guard("spawn route: " .. route.name,
                                                 route.fn, gm, pc)
                        if not ran then
                            Log.warn("  skipping this route - it crashed the game " ..
                                     "on an earlier run (rt.safety)")
                        end
                        -- Log.guard reports a Lua error. It cannot report a
                        -- native one, and the crash this file has already
                        -- produced left the log ending on the line above with
                        -- nothing after it. This line is how the next reader
                        -- tells "the route ran and did not help" apart from
                        -- "the route took the process down".
                        Log.info("  route %d returned", entry.attempts)
                    end
                end

            elseif entry then
                -- Was waiting for a body, is now on the way out. Forget them
                -- rather than escalating at a controller the engine is freeing.
                Log.info("%s left before they could be given a character",
                         shortName(key))
                watch[key]  = nil
                placed[key] = nil
            end
        end
    end

    -- Forget controllers that have disconnected.
    for key in pairs(watch) do
        if not seen[key] then watch[key] = nil end
    end
    for key in pairs(placed) do
        if not seen[key] then placed[key] = nil end
    end
end

--------------------------------------------------------------------------
-- Guest tick
--------------------------------------------------------------------------

--- A guest cannot spawn or possess anything - both are authority-only. All
--- this can do is notice, and say so clearly, because the alternative is the
--- player staring at black with nothing anywhere to tell them why.
function Spawn.tickClient(now)
    if not UE.IsClient() then
        clientPawnlessSince, clientWarned = nil, false
        return
    end

    local pawn = UE.GetPawn()
    if UE.valid(pawn) then
        if clientWarned then
            Log.info("you have a pawn now (%s) - you should be able to see and move",
                     UE.ClassNameOf(pawn))
        end
        clientPawnlessSince, clientWarned = nil, false
        return
    end

    if not clientPawnlessSince then
        clientPawnlessSince = now
        return
    end

    if not clientWarned and (now - clientPawnlessSince) > CLIENT_PATIENCE then
        clientWarned = true
        Log.error("=====================================================")
        Log.error(" You are connected to the host, but you have no")
        Log.error(" character yet - that is why the screen is black.")
        Log.error("")
        Log.error(" This is fixed on the HOST's machine, not yours.")
        Log.error(" Ask them to type  rt.fixpawns  in their game's console")
        Log.error(" (press ~ twice, type it, press Enter).")
        Log.error("")
        Log.error(" Nothing is broken on your end - stay connected while")
        Log.error(" they do it, and you will appear in the store.")
        Log.error("=====================================================")
        logReport()
    end
end

return Spawn
