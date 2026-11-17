--[[
    Rewind Together - what a guest carries is what the host says it carries

    REPORTED (16 Nov 2026, a friend over the Steam relay, 1.9.3): picking up
    tapes "bugging out", two tapes in the main hand, things ending up on the
    floor.

    MEASURED (two copies, 150 ms simulated lag): a guest's click runs twice -
    replayed on the host (guestinput.lua), which is the truth, and in the
    guest's own game, which reads the mouse itself. The guest's game decides
    against its own copy of the shelves, and a shelf slot's contents ("Object
    owning of this container") are a Blueprint variable that never replicates:
    on a guest every slot is empty. So a left click on a slot that is full on
    the host STORED the tape in the guest's game (its hand empty, the tape in
    the slot) while on the host the guest still held it. Nothing on the host
    changed, so replication never sent anything to correct it; the next clicks
    stacked further tapes on top of the wrong state.

    Every replicated actor carries the host's own record of what it is attached
    to (AActor::AttachmentReplication: parent, component, socket, offsets), and
    its replicated position (ReplicatedMovement). This module reads that record
    for anything the guest's game has on its hands, or that the host says it
    has, and once the host's answer to a press has had time to arrive, puts
    every item whose local place disagrees back where the host has it - the
    guest keeps its instant local response, and the host's result wins.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local CarrySync = {}

local EVERY        = 0.25    -- s between looks
local SETTLE       = 1.2     -- s after the guest's last press before correcting (the host's answer over a slow relay)
local ROLE_SIMULATED = 1     -- ENetRole: what a guest's copy of an actor from the host is (3: spawned here)
local SHELF_NEAR   = 300.0   -- cm: the shelf whose slot may think it holds a tape
local WATCH_FOR    = 10.0    -- s an item stays watched after it was last on this guest's hands
local SOCKETS      = { "AttachObject Socket", "AttachObject Inventory Socket" }
local OP           = "matching what a guest carries to the host (guest)"

local cfg = nil
local nextLook = 0
local lastPress = -1e9       -- os.clock() of this guest's last press (guestinput.lua tells us)
local watched = {}           -- item path -> watch until (os.clock())
local pending = {}           -- item path -> passes in a row it disagreed
local stats = { fixed = 0, looked = 0 }

function CarrySync.init(config) cfg = config end

--- guestinput.lua: the guest pressed something we send to the host.
function CarrySync.pressed() lastPress = os.clock() end

local function nameOf(o)
    local n = nil
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

--- The host's record of what `item` is attached to: parent actor, component,
--- socket name (FName), relative location and rotation. nil when unreadable.
local function hostRecord(item)
    local rep = UE.TryGet(item, "AttachmentReplication")
    if rep == nil then return nil end
    local r = {}
    pcall(function() r.parent = rep.AttachParent end)
    pcall(function() r.comp = rep.AttachComponent end)
    pcall(function() r.socket = rep.AttachSocket end)
    pcall(function() r.loc = UE.vec(rep.LocationOffset) end)
    pcall(function() r.rot = UE.rot(rep.RotationOffset) end)
    if not UE.valid(r.parent) then r.parent = nil end
    if not UE.valid(r.comp) then r.comp = nil end
    return r
end

--- Where the item is in this game: its root's attach parent and relative place.
local function localPlace(item)
    local root = UE.TryGet(item, "RootComponent")
    if not UE.valid(root) then return nil end
    local p = { root = root }
    pcall(function() p.comp = root:GetAttachParent() end)
    if not UE.valid(p.comp) then p.comp = nil end
    pcall(function() p.loc = UE.vec(root.RelativeLocation) end)
    return p
end

--- Is this the guest's copy of something the host replicates? Only those
--- have a host record to go by. What this game spawned itself - the popcorn
--- shovel and this game's own cup, the repair desk's tools - is Authority
--- here and is never touched.
local function fromHost(item)
    local role = UE.TryGet(item, "Role")
    return tonumber(role) == ROLE_SIMULATED
end

--- Does this game disagree with the host about WHOSE it is - on this guest
--- or not? Only that: where on the guest it sits (the hand, the stack, held
--- up to inspect with F) is this game's own business. `me`: this pawn's name.
local function disagrees(host, here, me)
    local hostMine = host.parent ~= nil and nameOf(host.parent) == me
    local owner = nil
    if here.comp then pcall(function() owner = here.comp:GetOwner() end) end
    local hereMine = owner ~= nil and nameOf(owner) == me
    return hostMine ~= hereMine
end

--- The slot of the shelf nearest `at` in this game that thinks it holds
--- `item`: forget it there. (Through the shelf's own list - listing every
--- Shelve_Container_C is a walk of every object, 155 ms, measured in 1.9.2.)
local function forgetInSlots(item, at)
    if not at then return end
    local name = nameOf(item)
    local best, bd = nil, SHELF_NEAR * SHELF_NEAR
    for _, shelf in ipairs(UE.findAll("Shelve_C") or {}) do
        local l = nil
        pcall(function() l = UE.vec(shelf:K2_GetActorLocation()) end)
        if l then
            local d = (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2
            if d < bd then best, bd = shelf, d end
        end
    end
    if not best then return end
    local slots = UE.TryGet(best, "All Selve Containers")
    if not slots then return end
    pcall(function()
        slots:ForEach(function(_, e)
            local c = nil
            pcall(function() c = e:get() end)
            local o = UE.valid(c) and UE.TryGet(c, "Object owning of this container") or nil
            if UE.valid(o) and nameOf(o) == name then
                UE.TrySet(c, "Object owning of this container", nil)
            end
        end)
    end)
end

--- Put the item where the host has it.
local function restore(item, host, here)
    local wasInSlot = here.comp == nil
    local at = nil
    pcall(function() at = UE.vec(item:K2_GetActorLocation()) end)
    if host.comp then
        local ok = pcall(function()
            item:K2_AttachToComponent(host.comp, host.socket or FName("None"), 0, 0, 0, false)   -- KeepRelative
        end)
        if not ok then return false end
        if host.loc and host.rot then
            pcall(UE.withHit, function(hit)
                here.root:K2_SetRelativeLocationAndRotation(host.loc, UE.rotArg(host.rot), false, hit, true)
            end)
        end
    else
        pcall(function() item:K2_DetachFromActor(1, 1, 1) end)                                     -- KeepWorld
        local rm = UE.TryGet(item, "ReplicatedMovement")
        local at, rot = nil, nil
        pcall(function() at = UE.vec(rm.Location) end)
        pcall(function() rot = UE.rot(rm.Rotation) end)
        if at then
            pcall(UE.withHit, function(hit)
                item:K2_SetActorLocationAndRotation(at, UE.rotArg(rot or { Pitch = 0, Yaw = 0, Roll = 0 }), false, hit, true)
            end)
        end
    end
    if wasInSlot then forgetInSlots(item, at) end
    return true
end

local function look(now)
    local pawn = UE.GetPawn()
    if not (UE.alive(pawn) and UE.ClassNameOf(pawn) == "Player_Character_C") then return end
    local me = nameOf(pawn)

    -- What this game has on the hands now, and what was there lately.
    local items = {}
    for _, sname in ipairs(SOCKETS) do
        local socket = UE.TryGet(pawn, sname)
        local n = 0
        if UE.valid(socket) then pcall(function() n = socket:GetNumChildrenComponents() end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            local owner = nil
            pcall(function() owner = socket:GetChildComponent(i):GetOwner() end)
            if UE.alive(owner) and not UE.sameObject(owner, pawn) then
                local path = UE.pathOf(owner)
                if path then items[path] = owner watched[path] = now + WATCH_FOR end
            end
        end
    end
    for path, untilT in pairs(watched) do
        if now > untilT then watched[path] = nil pending[path] = nil
        elseif not items[path] then
            local o = UE.findObject(path)
            if UE.alive(o) then items[path] = o else watched[path] = nil pending[path] = nil end
        end
    end

    local settled = (now - lastPress) >= SETTLE

    -- The game's own list of what is stacked ("Objects Inventory") is local
    -- too. MEASURED: after a left click on a full slot with a tape in hand the
    -- host's guest had nothing stacked and this game still listed one, which
    -- its next pick-up would have moved back into the hand. When every entry
    -- is somewhere else on the host, the list is emptied.
    if settled then
        local stack = UE.TryGet(pawn, "Objects Inventory")
        local entries, stale, localOnly = 0, 0, false
        if stack then
            pcall(function()
                stack:ForEach(function(_, e)
                    local o = nil
                    pcall(function() o = e:get() end)
                    entries = entries + 1
                    if UE.alive(o) and not fromHost(o) then localOnly = true end
                    local host = (UE.alive(o) and fromHost(o)) and hostRecord(o) or nil
                    if not (host and host.parent and nameOf(host.parent) == me) then stale = stale + 1 end
                end)
            end)
        end
        if entries > 0 and stale == entries and not localOnly then
            if pcall(function() stack:Empty() end) then
                stats.fixed = stats.fixed + 1
                Log.debug("carrying: this game listed %d stacked thing(s) the host does not - list emptied", entries)
            end
        end
    end

    for path, item in pairs(items) do
        stats.looked = stats.looked + 1
        local host = fromHost(item) and hostRecord(item) or nil
        local here = host and localPlace(item) or nil
        if host and here then
            -- On the host's hands of this guest: keep watching it.
            if host.parent and nameOf(host.parent) == me then watched[path] = now + WATCH_FOR end
            if disagrees(host, here, me) then
                pending[path] = (pending[path] or 0) + 1
                -- Two looks in a row, and the host has had time to answer the press.
                if settled and pending[path] >= 2 and restore(item, host, here) then
                    pending[path] = nil
                    stats.fixed = stats.fixed + 1
                    if stats.fixed == 1 then
                        Log.info("carrying: a %s was somewhere else in this game than on the host - put where the host has it",
                                 UE.ClassNameOf(item) or "thing")
                    end
                    Log.debug("carrying: %s put back as the host has it (%s)", path,
                              host.comp and ("on " .. tostring(nameOf(host.comp))) or "loose")
                end
            else
                pending[path] = nil
            end
        end
    end
end

--- Guest, every tick.
function CarrySync.tickGuest(now)
    if not UE.IsClient() then return end
    if cfg and cfg.SyncCarrying == false then return end
    if now < nextLook then return end
    nextLook = now + EVERY
    Safety.guard(OP, look, now)
end

function CarrySync.reset() watched, pending, lastPress, nextLook = {}, {}, -1e9, 0 end

function CarrySync.statusLines()
    return { ("Carrying: %d thing(s) put where the host has them"):format(stats.fixed) }
end

CarrySync._disagrees = disagrees

return CarrySync
