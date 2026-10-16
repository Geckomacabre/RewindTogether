--[[
    Rewind Together - things that fall land on guests' screens too

    MEASURED (15 Oct 2026, host and two guests through a lag proxy): a tape
    put down on the host lay on the host's floor, and on a guest's screen it
    hung in mid-air where it had left the hand.

    The game's own physics does that to anything thrown. PickupActor.txt,
    Toggle Simulate Physic: it is the Mesh component that simulates, not the
    actor's root (DefaultSceneRoot), and a simulating child leaves its parent
    (read off the dropped tape: simulating, attach parent none, root where the
    hand was). The actor replicates its movement, but its movement is the
    root's - which never moved. Physics only ever runs on the host, so on
    every guest a thrown tape stayed where it was let go until somebody picked
    it up. (Turning physics off puts the root on the mesh again, @255-@444;
    that is what picking it up does.)

    So the host notes what has physics on - a hook on Toggle Simulate Physic,
    rather than reading every tape in the store - and keeps each one's root on
    its mesh. The root moves, the mesh it no longer holds does not, and the
    guests' copies (whose meshes do sit on their roots) land where it landed.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Thrown = {}

local TOGGLE = {
    "/Game/VideoStore/core/blueprint/PickupActor.PickupActor_C:Toggle Simulate Physic",
    "/Game/VideoStore/asset/prop/movingbox/MovingBox.MovingBox_C:Toggle Simulate Physic",
}
local OP = "showing guests where thrown things land (host)"
local EVERY = 0.2            -- seconds between moves while something falls
-- Something that has come to rest keeps its physics on until it is picked up
-- again - for good, for a tape left on the floor. MEASURED: six of those, each
-- looked up five times a second, were 27 of the host's 50 path lookups a
-- second (each leaks a little in UE4SS, ue.lua). At rest: every few seconds.
local REST_EVERY = 5.0
local QUIET = 3              -- checks without a move before it counts as at rest
local NEAR = 2.0             -- cm: closer than this, the root is left alone
local MAX_FALLING = 128

local cfg = nil
local hooks = {}             -- function path -> the address it was hooked at
local nextHook, nextFollow = 0, 0
local falling = {}           -- actor path -> { at = next check, quiet = checks without a move }
local count = 0
local stats = { followed = 0 }

local function noteToggle(ctx, onP)
    if not UE.IsServer() then return end
    local actor = ctx
    pcall(function() actor = ctx:get() end)
    local on = onP
    pcall(function() on = onP:get() end)
    local path = UE.pathOf(actor)
    if not path then return end
    if on == true then
        if not falling[path] and count < MAX_FALLING then
            falling[path], count = { at = 0, quiet = 0 }, count + 1
        elseif falling[path] then
            falling[path].at, falling[path].quiet = 0, 0
        end
    elseif falling[path] then
        falling[path], count = nil, count - 1
    end
end

--- Hook both, and again when the class has been loaded anew (a new world):
--- a hook belongs to the function object it was put on.
local function hookAll(now)
    if now < nextHook then return end
    nextHook = now + 5
    for _, path in ipairs(TOGGLE) do
        local f = StaticFindObject(path)
        if UE.valid(f) then
            local addr = nil
            pcall(function() addr = f:GetAddress() end)
            if addr and hooks[path] ~= addr then
                local ok = pcall(function()
                    RegisterHook(path, function(ctx, onP)
                        Log.guard("thrown things hook", noteToggle, ctx, onP)
                    end)
                end)
                if ok then
                    hooks[path] = addr
                    Log.debug("thrown things: watching %s", path:match("([^/]+)$"))
                end
            end
        end
    end
end

--- Only a mesh that is simulating and has left its actor: moving the root of
--- one still attached would carry it along, and it would never catch up.
local function loose(mesh)
    local ok, sim = pcall(function() return mesh:IsSimulatingPhysics(FName("None")) end)
    if not (ok and sim == true) then return false end
    local parent = nil
    pcall(function() parent = mesh:GetAttachParent() end)
    return not UE.valid(parent)
end

local function follow(now)
    for path, f in pairs(falling) do
      if now >= f.at then
        local a = UE.findObject(path)
        local mesh = UE.alive(a) and UE.TryGet(a, "Mesh") or nil
        local root = UE.alive(a) and UE.TryGet(a, "RootComponent") or nil
        -- MEASURED: the game also drops the rented-out tapes - hidden, at the
        -- world's origin (83 of them) - with physics on. A hidden actor never
        -- reaches a guest; following those only filled the list.
        if not (UE.valid(mesh) and UE.valid(root)) or UE.sameObject(mesh, root)
                or UE.TryGet(a, "bHidden") == true or not loose(mesh) then
            -- Gone, hidden, the mesh IS the root (it replicates by itself), or
            -- held again.
            falling[path], count = nil, count - 1
        else
            local m = UE.vec(mesh:K2_GetComponentLocation())
            local r = UE.vec(a:K2_GetActorLocation())
            local moved = false
            if m and r then
                local dx, dy, dz = m.X - r.X, m.Y - r.Y, m.Z - r.Z
                if dx * dx + dy * dy + dz * dz > NEAR * NEAR then
                    local rot = UE.rotArg(UE.rot(mesh:K2_GetComponentRotation()))
                    UE.withHit(function(hit) a:K2_SetActorLocationAndRotation(m, rot, false, hit, true) end)
                    stats.followed = stats.followed + 1
                    moved = true
                end
            end
            f.quiet = moved and 0 or (f.quiet + 1)
            f.at = now + ((f.quiet >= QUIET) and REST_EVERY or EVERY)
        end
      end
    end
end

--- Host, every tick of a session.
function Thrown.tick(now)
    if not UE.IsServer() or (cfg and cfg.SyncThrownThings == false) then return end
    hookAll(now)
    if count <= 0 or now < nextFollow then return end
    nextFollow = now + EVERY
    Safety.guard(OP, follow, now)
end

function Thrown.report()
    return { ("Thrown things: %d falling now, %d moves sent to guests"):format(math.max(count, 0), stats.followed) }
end

function Thrown.reset()
    falling, count, nextFollow = {}, 0, 0
end

function Thrown.init(config)
    cfg = config
end

return Thrown
