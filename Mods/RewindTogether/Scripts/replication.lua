--[[
    Rewind Together - replication enabler

    Retro Rewind was built as a single-player game, so almost nothing in it is
    marked for replication. The engine's networking is fully intact though -
    the actors simply have bReplicates = false, so the server never tells
    anyone about them. We flip that on at runtime.

    Three rules learned the hard way, after the first build crashed and made
    the game stutter:

      1. NEVER touch an actor from a construction notification. Objects
         reported by NotifyOnNewObject are still being built; calling
         SetReplicates or GetLocalRole on one reaches into the world's network
         list mid-construction and takes the process down. New actors are
         queued and dealt with on a later tick instead.

      2. NEVER hook /Script/Engine.Actor. That fires for every actor the game
         ever creates - thousands, continuously, in a store full of spawning
         customers - and turned a cheap idea into a per-actor Lua call with
         string allocations inside it.

      3. Do nothing at all in single player. Replication only matters once a
         net driver exists, so until then this module costs zero.

    Class default objects are patched too, but they are NOT enough on their
    own. MEASURED in 1.7.0: a tape spawned on the host after its class
    default had bReplicates and bReplicateMovement set came out with
    bReplicates but not bReplicateMovement. A Blueprint actor copies only a
    precomputed list of properties from its class default when it spawns
    (the ones its Blueprint changed from the native defaults); the rest come
    from the C++ constructor. So every actor is checked, continuously, and
    patched when its own flags say it needs it. The check is cheap now that
    finding the actors is (UE.findAll).
]]

local Log = require("log")
local UE  = require("ue")

local Replication = {}

local cfg = nil
local patchedClasses  = {}   -- className -> true
local patchedActors   = {}   -- actor full name -> os.clock() of its last patch
local sweepCursor     = 1    -- round-robin position through ReplicatedClasses
local instanceCount   = 0
local active          = false

-- How many configured classes to examine per sweep. Spreading the work stops
-- the periodic full scan from showing up as a hitch.
local CLASSES_PER_SWEEP = 4

--------------------------------------------------------------------------

local function applyProperties(obj, isPawn, onDefault)
    local freq = isPawn and cfg.PawnNetUpdateFrequency or cfg.PropNetUpdateFrequency

    UE.TrySet(obj, "bReplicates", true)
    -- Never on a class default. Unreal sends a property only where it
    -- differs from the class default, so with the default patched to true a
    -- guest was never told the flag was on - and a guest's copy without it
    -- drops every position update (MEASURED in 1.7.0: 395 of 396 tapes on a
    -- guest had it off). Left alone on the default, each patched actor's
    -- true differs from it and goes out to every guest with the actor.
    if not onDefault then UE.TrySet(obj, "bReplicateMovement", true) end

    -- DORM_Awake == 0.
    --
    -- A dormant actor stops sending updates entirely. The guest keeps the last
    -- position it was told and nothing ever corrects it - which is exactly the
    -- reported symptom of a movie the host drops staying in mid-air on the
    -- guest's screen while it lies on the floor on the host's.
    --
    -- A single-player game has every reason to mark its scenery dormant: it is
    -- free performance when nothing is replicating. DORM_Initial in particular
    -- means "never replicate this after spawn", which is indistinguishable
    -- from a broken channel from the outside.
    --
    -- Whether that is what is happening here is NOT established. What is
    -- established is that it costs one property write to rule out, and that
    -- leaving it unset means never knowing.
    UE.TrySet(obj, "NetDormancy", 0)

    UE.TrySet(obj, "NetUpdateFrequency", freq)
    UE.TrySet(obj, "MinNetUpdateFrequency", math.max(2, math.floor(freq / 4)))
    UE.TrySet(obj, "NetPriority", isPawn and 3.0 or 1.5)

    if cfg.AlwaysRelevant then
        UE.TrySet(obj, "bAlwaysRelevant", true)
    else
        -- 150m covers the whole store. Leaving distance culling on keeps the
        -- server from serialising every prop to every client every update,
        -- which is what made the first build saturate and stutter.
        UE.TrySet(obj, "NetCullDistanceSquared", 225000000.0)
    end
end

--------------------------------------------------------------------------
-- CDO patching - the cheap path that covers all future spawns
--------------------------------------------------------------------------

local function getCDO(actor)
    local cdo = nil
    pcall(function()
        local cls = actor:GetClass()
        if not UE.valid(cls) then return end
        if cls.GetCDO then cdo = cls:GetCDO() end
        if not UE.valid(cdo) and cls.GetDefaultObject then cdo = cls:GetDefaultObject() end
        if not UE.valid(cdo) then
            local full = cls:GetFullName()
            local path = full:match("%s(.+)$")
            if path then
                local pkg, name = path:match("^(.-)%.([^%.]+)$")
                if pkg and name then
                    cdo = StaticFindObject(pkg .. ".Default__" .. name)
                end
            end
        end
    end)
    return cdo
end

local function patchClassOnce(actor, className, isPawn)
    if patchedClasses[className] then return end
    patchedClasses[className] = true

    local cdo = getCDO(actor)
    if UE.valid(cdo) then
        applyProperties(cdo, isPawn, true)
        Log.info("replication enabled on class %s", className)
    else
        Log.debug("no CDO resolved for %s; per-instance only", className)
    end
end

--------------------------------------------------------------------------
-- Instance patching
--------------------------------------------------------------------------

--- Patch one fully-constructed actor. Safe to call from a tick, never from a
--- construction callback.
--- Stop the server yanking a sprinting guest backwards.
---
--- Reported from a live session: the guest moves smoothly until they hold
--- shift, and then it jitters. That is not lag and it is not the network. It
--- is the server correcting them, several times a second.
---
--- Retro Rewind is a single-player game, so its sprint runs entirely on the
--- machine that pressed the key - the Blueprint raises the character's walk
--- speed locally and there is no server RPC to tell anybody, because there has
--- never been anybody to tell. The server then replays the guest's moves at
--- its OWN idea of their speed, finds them further ahead than it believes is
--- possible, and sends ClientAdjustPosition. The client snaps back, sprints
--- ahead again, gets snapped back again. Hence jitter that appears only while
--- the key is held.
---
--- bIgnoreClientMovementErrorChecksAndCorrection is the engine's own switch
--- for this exact situation: the server takes the client's word for where it
--- is. Movement becomes client-authoritative for guests, which in a co-op
--- store game played with a friend costs nothing anybody cares about, and is
--- the only option available anyway - the alternative is a server RPC, and
--- RPCs cannot be added to a cooked Blueprint.
---
--- AUTHORITY ONLY. It is the server's copy of the movement component that runs
--- the check, so setting this anywhere else achieves nothing at all.
local function trustClientMovement(pawn)
    local move = UE.TryGet(pawn, "CharacterMovement")
    if not UE.alive(move) then return nil end
    local PROP = "bIgnoreClientMovementErrorChecksAndCorrection"
    UE.TrySet(move, PROP, true)
    local got = UE.TryGet(move, PROP)
    -- Booleans come back as true or 1 depending on how the bitfield is
    -- published; nil means the property is not readable on this build, which
    -- is not the same as the write having failed and must not be reported as
    -- success.
    if got == true or got == 1 then return true end
    if got == nil then return nil end
    return false
end

local function patchInstance(actor, isPawn)
    if not UE.alive(actor) then return false end

    local key
    local okKey = pcall(function() key = actor:GetFullName() end)
    if not okKey or key == nil then return false end
    -- The caller already checked the actor's flags. This only stops one whose
    -- flags will not take from being patched again on every sweep.
    local now = os.clock()
    local last = patchedActors[key]
    if last and (now - last) < 30 then return false end
    local firstTime = (last == nil)
    patchedActors[key] = now

    applyProperties(actor, isPawn)

    -- SetReplicates is authority-only and asserts otherwise.
    local authority = false
    local ok = pcall(function()
        if actor:GetLocalRole() == UE.ROLE_AUTHORITY then
            authority = true
            actor:SetReplicates(true)
            actor:SetReplicateMovement(true)
        end
    end)
    if not ok then return false end

    -- Setting NetDormancy on an actor that is ALREADY asleep does not wake it;
    -- the engine needs telling. Authority-only, like everything else that
    -- touches the network state of an actor.
    if authority then
        pcall(function() actor:FlushNetDormancy() end)
    end

    if authority and isPawn and firstTime then
        local trusted = trustClientMovement(actor)
        if trusted == true then
            Log.info("%s: server will not correct this client's movement - " ..
                     "sprint should stop jittering", UE.ClassNameOf(actor))
        elseif trusted == false then
            Log.warn("%s: could not stop the server correcting this client. " ..
                     "Sprinting will jitter; the property would not take.",
                     UE.ClassNameOf(actor))
        elseif trusted == nil then
            Log.debug("%s: no CharacterMovement, or the correction flag is not " ..
                      "readable here - cannot say whether sprint will jitter",
                      UE.ClassNameOf(actor))
        end
    end

    instanceCount = instanceCount + 1
    return true
end

--- Does this actor still need patching? Its own flags say so: they are what
--- the engine reads, and (top of this file) a class default is no promise
--- about an actor spawned from it.
local function needsPatch(actor, isPawn)
    if UE.TryGet(actor, "bReplicateMovement") ~= true then return true end
    if UE.TryGet(actor, "bReplicates") ~= true then return true end
    if isPawn then
        local move = UE.TryGet(actor, "CharacterMovement")
        if UE.alive(move)
           and UE.TryGet(move, "bIgnoreClientMovementErrorChecksAndCorrection") == false then
            local authority = false
            pcall(function() authority = actor:GetLocalRole() == UE.ROLE_AUTHORITY end)
            if authority then return true end
        end
    end
    return false
end

--- Every live instance of a configured class. The config names Blueprints
--- without their _C; the bare name is only asked about when no _C class by
--- that name exists, so a native class can still be listed.
local function instancesOf(want)
    local list = UE.findAll(want .. "_C")
    if list then return list end
    if UE.classKnown(want .. "_C") then return {} end
    return UE.findAll(want) or {}
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function Replication.init(config)
    cfg = config
end

--- Enable/disable all work. Called when a session starts or ends.
function Replication.resetGuest()
    Replication._resetGuestState()
end

function Replication.setActive(on)
    if active == on then return end
    active = on
    Log.info("replication %s", on and "active" or "idle (single player)")
end

function Replication.isActive() return active end

--- Round-robin slice of the full sweep. Cheap enough to call every few
--- seconds without the player noticing.
function Replication.sweep()
    if not cfg or not active then return 0 end

    -- SERVER ONLY. A client has no business marking its own class defaults as
    -- replicating, and doing so appears to be actively harmful here.
    --
    -- The evidence: on the guest, walls, shelves and the counter render as
    -- yellow-and-black placeholder boxes while everything else in the level -
    -- cobbles, planters, signs, doorways, NPCs - looks perfect. The striped
    -- objects are precisely the classes listed in Config.ReplicatedClasses,
    -- which is far too close a match to be a coincidence.
    --
    -- The mechanism: AActor derives Role and RemoteRole from its CDO during
    -- PostInitializeComponents. Setting bReplicates on a CDO *on a client*
    -- tells every level-placed actor of that class that it is a network proxy
    -- awaiting server data, rather than a thing the level already fully
    -- describes - so it stops running its own setup and draws in its
    -- unconfigured default state. Which is a yellow box.
    --
    -- Replication configuration is authority-side by definition. The guest
    -- gets replicated actors because the SERVER decided to send them.
    if cfg.PatchReplicationOnClients ~= true and UE.IsClient() then return 0 end

    local classes = cfg.ReplicatedClasses
    local patched = 0

    -- Not retired after one pass any more: actors spawned later (stock from a
    -- delivery, a wall placed in build mode) are covered only by their own
    -- flags, see the top of this file. This was the step that crashed when
    -- the tick still ran off the game thread (main.lua); on the game thread,
    -- with UE.alive checked first, an actor from this frame's list is safe.
    if sweepCursor > #classes then sweepCursor = 1 end
    for _ = 1, math.min(CLASSES_PER_SWEEP, #classes) do
        local want = classes[sweepCursor]
        sweepCursor = sweepCursor % #classes + 1
        if want then
            local isPawn = (want == "Player_Character")
                or want:find("Character") ~= nil
                or want:find("Staff") ~= nil
                or want:find("Customer") ~= nil
            for _, actor in ipairs(instancesOf(want)) do
                if UE.alive(actor) then
                    patchClassOnce(actor, want, isPawn)
                    if needsPatch(actor, isPawn) and patchInstance(actor, isPawn) then
                        patched = patched + 1
                    end
                end
            end
        end
    end

    if patched > 0 then
        Log.debug("sweep patched %d actor(s)", patched)
    end
    return patched
end

--[[
    GUEST: bReplicateMovement, and nothing else.

    MEASURED in 1.7.0: a guest put a tape back on the shelf it came from; the
    host's copy was on the shelf, the guest's floated where the hand had been,
    and even a forced net update did not move it. On the guest that tape had
    bReplicateMovement = FALSE, and so did 395 of the guest's 396 tapes.

    Two causes, both fixed: the host never told guests the flag (its class
    defaults carried it, see applyProperties), and a class default cannot
    give it to a spawned actor anyway (top of this file). AActor::
    OnRep_ReplicatedMovement returns at once without the flag, so every
    position update for those actors was dropped. Attachments still worked:
    that is a different property, and its OnRep does not check this flag.

    With the host fixed this should find nothing. It stays as the guest's own
    check, because what it catches is an object that silently stops moving
    for one player only.

    Setting ONLY this flag on a guest is safe: it decides whether received
    movement is applied, not whether the actor thinks it is a network proxy
    (that is bReplicates, which a guest must never touch - see above).
]]
local guestCursor = 1
local guestNextSlice = 0
local guestFixed = 0
local GUEST_SLICE_EVERY = 2.0     -- seconds per slice: the whole list in ~14 s

--- The position the host last sent was stored on the actor even while the
--- flag was off: apply it now. Not while attached (the attachment decides),
--- and not if nothing was ever received - all zeros is the world origin.
local function applyLastMovement(actor)
    local rm = UE.TryGet(actor, "ReplicatedMovement")
    local loc = rm and UE.vec(UE.field(rm, "Location"))
    if not loc or (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then return end
    local parent = nil
    pcall(function() parent = actor:GetAttachParentActor() end)
    if UE.valid(parent) then return end
    pcall(function() actor:OnRep_ReplicatedMovement() end)
end

function Replication._resetGuestState()
    guestCursor, guestNextSlice, guestFixed = 1, 0, 0
end

function Replication.patchGuestMovement()
    if not cfg or not active or not UE.IsClient() then return 0 end
    local t = os.clock()
    if t < guestNextSlice then return 0 end
    guestNextSlice = t + GUEST_SLICE_EVERY

    local classes = cfg.ReplicatedClasses
    local fixed = 0
    if guestCursor > #classes then guestCursor = 1 end
    for _ = 1, math.min(CLASSES_PER_SWEEP, #classes) do
        local want = classes[guestCursor]
        guestCursor = guestCursor % #classes + 1
        for _, actor in ipairs(want and instancesOf(want) or {}) do
            if UE.TryGet(actor, "bReplicateMovement") == false and UE.alive(actor) then
                UE.TrySet(actor, "bReplicateMovement", true)
                applyLastMovement(actor)
                fixed = fixed + 1
            end
        end
    end
    if fixed > 0 then
        guestFixed = guestFixed + fixed
        Log.info("guest: %d actor(s) were ignoring the host's movement updates " ..
                 "and now apply them (%d this session)", fixed, guestFixed)
    end
    return fixed
end

--- Full pass over every configured class. Used once when a session starts,
--- where a one-off cost is fine and completeness matters.
function Replication.sweepAll()
    if not cfg or not active then return 0 end
    local total = 0
    for _ = 1, math.ceil(#cfg.ReplicatedClasses / CLASSES_PER_SWEEP) do
        total = total + Replication.sweep()
    end
    -- Says "newly", because it does not on the second call and that has now
    -- twice been read as a failure. sweepAll runs once when the session starts
    -- and again when a player joins; by the second run every actor already
    -- carries its flags and zero is the correct answer, not a broken one. A
    -- count that means "nothing left to do" must not look like a count that
    -- means "nothing worked".
    Log.info("initial replication pass: %d actor(s) NEWLY patched across %d class(es)",
             total, #cfg.ReplicatedClasses)
    return total
end

--- Spawn hooks are deliberately not used.
---
--- An earlier build queued newly constructed pawns and patched them a tick
--- later. That crashed: this game spawns and despawns AI customers
--- constantly, so by the time the queue was drained some of those objects had
--- already been collected, and touching a freed UObject through UE4SS's
--- bridge is an access violation.
---
--- The sweep finds new actors instead, from a fresh list every time: a class
--- default does not reach them (top of this file), and holding no actor
--- pointers across frames removes that entire class of bug.
function Replication.installSpawnHooks()
    Log.info("replication: every actor checked by a periodic sweep, no " ..
             "per-spawn callbacks (no actor pointers are held across frames)")
end

--- Retained as a no-op so callers do not need to care which strategy is used.
function Replication.drainPending()
    return 0
end

function Replication.raisePlayerCap(maxPlayers)
    local gm = UE.GetGameMode()
    if not UE.valid(gm) then return false end

    local applied = false
    if UE.TrySet(gm, "MaxPlayers", maxPlayers) then applied = true end

    local session = UE.TryGet(gm, "GameSession")
    if UE.valid(session) then
        if UE.TrySet(session, "MaxPlayers", maxPlayers) then applied = true end
        UE.TrySet(session, "MaxSpectators", 2)
    end
    if applied then Log.info("player cap set to %d", maxPlayers) end
    return applied
end

function Replication.stats()
    local classes = 0
    for _ in pairs(patchedClasses) do classes = classes + 1 end
    return { classes = classes, instances = instanceCount, active = active }
end

return Replication
