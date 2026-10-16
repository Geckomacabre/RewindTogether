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
-- the periodic full scan from showing up as a hitch. MEASURED (16 Oct 2026,
-- frame times on two copies): four classes at a time froze the host's frame
-- for up to 87 ms every 2 s - the tapes alone are 479 actors (5 ms to list,
-- 40 us each to check). One class per call, called four times as often
-- (main.lua), sweeps the same list as fast in a quarter of the hitch.
local CLASSES_PER_SWEEP = 1
-- Classes whose instances included a child actor on a full pass: only those
-- need every instance asked who its parent is (see "Child actors" below).
local childClasses = {}
local childChecked = {}
-- At most this many of one class per call: a big class (PickupActor, 568 in
-- the test store) goes over a few calls, from where the last one stopped.
-- The list is fetched again each call (actors are never kept across frames).
local SWEEP_CHUNK = 120
local sweepOffset = 0

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
---
--- ...and bServerAcceptClientAuthoritativePosition with it. Not correcting the
--- guest is half of trusting them: the server still simulated its own copy
--- from its own idea of where they were, so any difference between the two -
--- a step one side climbed and the other did not - stayed for good. MEASURED
--- (two copies, the guest walked by its own movement input): with only the
--- first flag the host's copy of the guest kept a 194-unit offset through a
--- 260-unit walk; with both, the host's copy stood exactly where the guest
--- did (1300,-1312 on both). REPORTED as "there is no guest pawn": the host
--- saw the guest's body somewhere the guest was not. Sprint, MEASURED with
--- both flags (the guest's position every frame, Run Speed 550 on the guest
--- only): 994 units in 150 frames, no step back over 1 unit, the host's copy
--- where the guest was; corrections on, the same sprint: 33 snap-backs of up
--- to 85 units.
local function trustClientMovement(pawn)
    local move = UE.TryGet(pawn, "CharacterMovement")
    if not UE.alive(move) then return nil end
    UE.TrySet(move, "bServerAcceptClientAuthoritativePosition", true)
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

--[[
    A MOVE THE HOST MAKES TO A GUEST'S PAWN (spawn.lua: the placement after a
    join, rt.bring). With the guest's position trusted the guest is never told
    - nothing corrects them - and the host takes the guest's old position
    straight back from their next move. MEASURED: a join placement undone,
    both copies left at the spawn point (2367,177,-408). So for a moment
    around such a move the engine checks the guest again, which sends them the
    new position (ClientAdjustPosition), and then trust returns. MEASURED: the
    guest's own copy was at the new spot (2495,41) on both machines within 2 s.
    The engine corrects a guest only in reply to one of their moves, so the
    window is generous: a guest who has just joined over the internet may be
    hitching (loading shaders, streaming) at exactly that moment.
]]
local untrusted = {}            -- pawn path -> os.clock() when trust comes back
local UNTRUST_FOR = 5.0

function Replication.beforeHostMovesGuest(pawn)
    if not UE.IsServer() or not UE.alive(pawn) then return end
    local c = UE.TryGet(pawn, "Controller")
    if UE.alive(c) and UE.IsLocalController(c) then return end   -- the host's own
    local move = UE.TryGet(pawn, "CharacterMovement")
    local path = UE.pathOf(pawn)
    if not (UE.alive(move) and path) then return end
    UE.TrySet(move, "bIgnoreClientMovementErrorChecksAndCorrection", false)
    UE.TrySet(move, "bServerAcceptClientAuthoritativePosition", false)
    untrusted[path] = os.clock() + UNTRUST_FOR
end

local function stillUntrusted(pawn)
    local path = UE.pathOf(pawn)
    return path ~= nil and untrusted[path] ~= nil
end

--- Host, every tick: trust comes back once the guest has been told.
function Replication.restoreTrust(clock)
    if next(untrusted) == nil then return end
    local t = clock or os.clock()
    for path, at in pairs(untrusted) do
        if t >= at then
            untrusted[path] = nil
            local pawn = UE.findObject(path)
            if UE.alive(pawn) then trustClientMovement(pawn) end
        end
    end
end

--- A pawn a remote player controls, whose role on that player's machine is
--- not AutonomousProxy (see patchInstance). Host only.
local ROLE_AUTONOMOUS = 2
local function remotePlayerPawn(pawn)
    local c = UE.TryGet(pawn, "Controller")
    if not UE.alive(c) then return false end
    local isPlayer = false
    pcall(function() isPlayer = c:IsPlayerController() end)
    return isPlayer and not UE.IsLocalController(c)
end

local function demoted(pawn)
    return remotePlayerPawn(pawn) and tonumber(UE.TryGet(pawn, "RemoteRole")) ~= ROLE_AUTONOMOUS
end

local function repairAutonomous(pawn)
    if not demoted(pawn) then return false end
    UE.TrySet(pawn, "RemoteRole", ROLE_AUTONOMOUS)
    pcall(function() pawn:ForceNetUpdate() end)
    local fixed = tonumber(UE.TryGet(pawn, "RemoteRole")) == ROLE_AUTONOMOUS
    if fixed then
        Log.info("%s: a guest's own pawn was not theirs to move (SimulatedProxy) - put back",
                 UE.ClassNameOf(pawn))
    end
    return fixed
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

    -- SetReplicates BEFORE anything writes bReplicates. It is the call that
    -- puts the actor on the net driver's list (AddNetworkActor), and it only
    -- does that when it sees the flag go from false to true. MEASURED: this
    -- used to run applyProperties first, which writes bReplicates = true
    -- straight into the property; SetReplicates then found nothing to do. A
    -- furniture box spawned in build mode sat on the host with bReplicates =
    -- true and RemoteRole = SimulatedProxy and never reached the guest -
    -- toggling SetReplicates(false) / (true) put it on the guest's screen at
    -- once. Anything spawned during play from a class whose Blueprint does not
    -- set bReplicates itself (boxes, deliveries) was invisible to guests.
    -- SetReplicates is authority-only and asserts otherwise.
    --
    -- And ONLY to start an actor replicating. On UE 5 SetReplicates(true) also
    -- sets RemoteRole = SimulatedProxy, every time, replicating already or not
    -- - and a guest's own pawn must be an AutonomousProxy on the guest's
    -- machine, the role that moves by its input and sends its moves to the
    -- host. MEASURED: once this sweep had patched a guest's pawn, its role on
    -- the guest was SimulatedProxy; movement input did nothing (a simulated
    -- proxy only follows the server) and the host's copy never moved. Put back
    -- to AutonomousProxy (RemoteRole = 2 on the host), the guest walked and
    -- the host's copy walked with it.
    local authority = false
    local ok = pcall(function()
        if actor:GetLocalRole() == UE.ROLE_AUTHORITY then
            authority = true
            if UE.TryGet(actor, "bReplicates") ~= true then actor:SetReplicates(true) end
            actor:SetReplicateMovement(true)
        end
    end)
    if not ok then return false end

    applyProperties(actor, isPawn)

    -- Setting NetDormancy on an actor that is ALREADY asleep does not wake it;
    -- the engine needs telling. Authority-only, like everything else that
    -- touches the network state of an actor.
    if authority then
        pcall(function() actor:FlushNetDormancy() end)
    end

    if authority and isPawn then repairAutonomous(actor) end

    if authority and isPawn and not stillUntrusted(actor) then
        local trusted = trustClientMovement(actor)
        if not firstTime then
            -- said once per pawn
        elseif trusted == true then
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

--[[
    CHILD ACTORS ARE EVERY MACHINE'S OWN. An actor a ChildActorComponent
    spawned - the snack display's boxes (SnackBox_Snack_C, under each
    SnackShelf) - is spawned by its parent on every machine, guest included.
    Replicating the host's as well gave a guest a SECOND set, attached in the
    same place. MEASURED (two copies, NPCs sampled every frame): the second
    set's triggers had collision on where the host's had it off, and a
    customer walking past the display climbed the invisible boxes on the
    guest's screen - up to a metre - and was pulled back down by the host's
    position every few frames: the "NPCs shake" report. So a child actor is
    never made to replicate, and one already replicating is switched off. (A
    guest that already holds a copy keeps it until it joins again - MEASURED,
    the engine does not take it back - but a session that starts with this
    never sends one: 4 boxes, 8 triggers, 4 meshes on both machines, none
    replicated.) With that, customers passing the display - one within 6
    units of a button - moved on the guest as on the host (mesh height
    steady, steps back of 2.5 units at most).
]]
local childWarned = {}

local function isChildActor(actor)
    local parent = nil
    pcall(function() parent = actor:GetParentActor() end)
    return UE.valid(parent)
end

local function unreplicateChild(actor, className)
    if UE.TryGet(actor, "bReplicates") ~= true then return false end
    local ok = pcall(function()
        if actor:GetLocalRole() == UE.ROLE_AUTHORITY then actor:SetReplicates(false) end
    end)
    if ok and not childWarned[className] then
        childWarned[className] = true
        Log.info("%s: child actors are built on every machine - not replicated " ..
                 "(guests had two of each)", className)
    end
    return ok
end

--- Does this actor still need patching? Its own flags say so: they are what
--- the engine reads, and (top of this file) a class default is no promise
--- about an actor spawned from it.
local function needsPatch(actor, isPawn)
    if UE.TryGet(actor, "bReplicateMovement") ~= true then return true end
    if UE.TryGet(actor, "bReplicates") ~= true then return true end
    if isPawn then
        local authority = false
        pcall(function() authority = actor:GetLocalRole() == UE.ROLE_AUTHORITY end)
        if authority then
            local move = UE.TryGet(actor, "CharacterMovement")
            if UE.alive(move) and not stillUntrusted(actor)
               and (UE.TryGet(move, "bIgnoreClientMovementErrorChecksAndCorrection") == false
                    or UE.TryGet(move, "bServerAcceptClientAuthoritativePosition") == false) then
                return true
            end
            if demoted(actor) then return true end
        end
    end
    return false
end

--- Every live instance of a configured class. The config names Blueprints
--- without their _C; the bare name is only asked about when no _C class by
--- that name exists, so a native class can still be listed.
local bareMissed = {}
local function instancesOf(want)
    -- Not actors at all - Shelve_Container and BoxStorage_Container are the
    -- shelves' StaticMeshComponents (header dump) - so nothing here applies to
    -- them, and finding them is a walk of every object in the engine.
    -- MEASURED (16 Oct 2026): 155 ms of one host frame for the boxes' one.
    if UE.classIsNotActor(want .. "_C") then return {} end
    local list = UE.findAll(want .. "_C")
    if list then return list end
    if UE.classKnown(want .. "_C") or bareMissed[want] then return {} end
    -- A native class by its bare name: asked once; names the game does not
    -- have (Config's "AI_Character", "Customer") cost a walk each time.
    list = UE.findAll(want)
    if not list then bareMissed[want] = true end
    return list or {}
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
    if sweepCursor > #classes then sweepCursor, sweepOffset = 1, 0 end
    for _ = 1, math.min(CLASSES_PER_SWEEP, #classes) do
        local want = classes[sweepCursor]
        if not want then
            sweepCursor, sweepOffset = sweepCursor % #classes + 1, 0
        else
            local isPawn = (want == "Player_Character")
                or want:find("Character") ~= nil
                or want:find("Staff") ~= nil
                or want:find("Customer") ~= nil
            -- A class with child-actor instances keeps its class default:
            -- patched, a child spawned later would replicate from birth and the
            -- guest's copy would outlive the sweep switching it off.
            local list = instancesOf(want)
            -- Once per class: does any of it come from a ChildActorComponent?
            -- Asked of every instance on that first pass only, and again of
            -- every instance only for classes where one did.
            if not childChecked[want] then
                childChecked[want] = true
                for _, actor in ipairs(list) do
                    if UE.alive(actor) and isChildActor(actor) then childClasses[want] = true break end
                end
            end
            local hasChild = childClasses[want] == true
            local first = sweepOffset + 1
            local last = math.min(#list, sweepOffset + SWEEP_CHUNK)
            if last >= #list then
                sweepCursor, sweepOffset = sweepCursor % #classes + 1, 0
            else
                sweepOffset = last
            end
            for i = first, last do
                local actor = list[i]
                -- valid, not alive, for the cheap reads: this frame's list.
                -- alive (four engine calls) only before anything is written.
                if UE.valid(actor) then
                    if hasChild and isChildActor(actor) then
                        unreplicateChild(actor, want)
                    elseif needsPatch(actor, isPawn) and UE.alive(actor) then
                        if isChildActor(actor) then
                            -- One that appeared since the class was first looked at.
                            childClasses[want] = true
                            unreplicateChild(actor, want)
                        else
                            if not hasChild then patchClassOnce(actor, want, isPawn) end
                            if patchInstance(actor, isPawn) then patched = patched + 1 end
                        end
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

--- One actor the sweep never lists, made to replicate now: a module that
--- knows a particular actor must reach the guests (guestinput.lua: the change
--- counted onto the counter) when its whole class must not - the drawer's
--- own stacks of the same classes exist on every machine already. The same
--- order and flags as the sweep. Host only. Returns true when it patched.
function Replication.patchActor(actor, isPawn)
    if not cfg or not UE.IsServer() or not UE.alive(actor) then return false end
    if isChildActor(actor) then return false end       -- every machine's own (above)
    if not needsPatch(actor, isPawn == true) then return false end
    return patchInstance(actor, isPawn == true)
end

--- Full pass over every configured class. Used once when a session starts,
--- where a one-off cost is fine and completeness matters.
function Replication.sweepAll()
    if not cfg or not active then return 0 end
    local total = 0
    -- Whole classes here, from the first: completeness is the point.
    local chunk = SWEEP_CHUNK
    SWEEP_CHUNK, sweepCursor, sweepOffset = math.huge, 1, 0
    local ok, err = pcall(function()
        for _ = 1, math.ceil(#cfg.ReplicatedClasses / CLASSES_PER_SWEEP) do
            total = total + Replication.sweep()
        end
    end)
    SWEEP_CHUNK = chunk
    if not ok then error(err, 0) end
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
