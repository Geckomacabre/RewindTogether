--[[
    Rewind Together - popcorn, slushies and cotton candy for a guest

    MEASURED (live, 16 Oct 2026, two copies). Worked the way the return desk
    is (machines.lua: the host sits the guest down at ITS machine and replays
    the guest's clicks and drags there), the popcorn machine goes half way:
    the guest's drag on the kettle lever poured the host's popcorn (fullness
    0 -> 1.0). The other half cannot work like that. The shovel
    (Popcorn-Shovel_C, spawned by the shovel holder's Pickup) follows the
    LOCAL mouse on every tick - DeprojectMousePositionToWorld or a trace from
    player 0's camera manager, bp/Popcorn-Shovel.txt @1585 - and scoops on
    its own input binding; and a full cup goes to player 0 a tick later
    (PopcornMachine "PopcornCup is full_Event" @4857: DelayUntilNextTick,
    then Give Cup to player), outside any window in which the host answers
    for a guest. On the host the shovel would follow the host's mouse and the
    cup would land in the host's hands. The slushie and cotton-candy machines
    are built the same way (a cup or stick picked up by player 0 at the end:
    SlushMachine "Move Cup To The Player Hand" @309, CottonCandyMachine "Give
    Cotton Stick to player" @4463), and none of the three uses anything of
    the store's: no stock, no saved state but bought and the popcorn level.

    So a guest makes them on its own screen, where its game is the
    single-player game it was built as (the machines bought and powered on
    the guest: worldsync.lua), and the host makes the results real:

      * The popcorn level. The host sends each machine's level; a guest's
        copy follows it, except while that guest works the machine - then the
        guest's copy is the one that changes (the kettle pours, the shovel
        takes), and the guest sends it (action 17) and the host's follows.
      * The product. The guest's game gives its own cup or stick to its own
        pawn - made on the guest, which nobody else can see or sell. Seen in
        the guest's hands, it is put away and the host is told what it was
        (action 18: which, how full, which flavour or colour); the host makes
        one, fills and flavours it the product's own way, and puts it in the
        guest's hands as the guest - a real, replicated product, sold like
        any other.
      * How full, which flavour: none of it replicates (MEASURED: the cup the
        host put in a guest's hands, full there, read 0 on the guest and
        showed empty). The host sends what each player holds, and what stands
        in the machines (by place: there it stands in the same spot on every
        copy); a guest's copies are filled and flavoured to match. Products
        in anybody else's hands (a customer's) are shown full.
      * While a guest works a machine, the host's own products standing in it
        (replicated) are hidden on the guest's screen: they stand exactly
        where the guest's own do.

    The clicks a guest makes at these machines stay on the guest's screen
    (guestinput.lua: LOCAL_PLAY), and the host does not sit the guest down
    (machines.lua).
]]

local Log  = require("log")
local UE   = require("ue")
local Chan = require("rpcchan")

local Conc = {}

local ACTION_FILL = 17
local ACTION_GIVE = 18

local POPCORN = "PopcornMachine_C"
local LEVEL   = "Popcorn Fullness Normalize"
local FILL    = "Fill Percentage Alpha"

-- What a guest's game can hand it. `kind` is its number on the wire; fill
-- and flavour are the product's own (its function adds to the fill).
local PRODUCTS = {
    PopcornCup_C = { kind = 1, label = "a cup of popcorn", fill = "Fill Popcorn",
                     class = "/Game/VideoStore/asset/prop/Popcorn/PopcornCup.PopcornCup_C",
                     machine = "PopcornMachine_C" },
    SlushCup_C = { kind = 2, label = "a slushie", fill = "Fill Slush", flavour = "Flavour", setFlavour = "Set Flavour",
                   class = "/Game/VideoStore/asset/prop/Slush/SlushCup.SlushCup_C",
                   machine = "SlushMachine_C" },
    CottonCandy_Stick_C = { kind = 3, label = "a cotton candy", fill = "Fill CottonCandy", flavour = "Color",
                            setFlavour = "Set Color",
                            class = "/Game/VideoStore/asset/prop/CottonCandy/CottonCandy_Stick.CottonCandy_Stick_C",
                            machine = "CottonCandyMachine_C" },
}
local BY_KIND, MACHINES = {}, {}
for cls, p in pairs(PRODUCTS) do
    p.cls = cls
    BY_KIND[p.kind] = p
    MACHINES[p.machine] = p
end

local SEND_EVERY   = 1.0      -- host: levels, products, hands - to guests
local RESEND       = 4.0      -- host: again, unchanged (a guest who just joined)
local REPORT_EVERY = 0.3      -- guest: its popcorn level while it works the machine
local HANDS_EVERY  = 0.25     -- guest: a product of its own in its hands?
local HELD_EVERY   = 0.5      -- guest: products in hands nobody described, shown full
local GIVE_ONCE    = 2.0      -- host: one product per guest per this long (an action arrives twice)
local NEAR         = 150.0    -- cm: a machine named by its place is the nearest within this
local IN_MACHINE   = 90.0     -- cm: a product "in" a machine
local MATCH        = 40.0     -- cm: the guest's copy of a product in a machine is the nearest within this

-- The wire carries the product in the rotator's yaw (kind x 60 + fill x 50)
-- and its flavour in the pitch: a rotator crosses the network as three
-- angles in 0..360 (FRotator::NetSerialize), so every value stays below that.
local KIND_STEP, FILL_SPAN = 60.0, 50.0

local ROLE_AUTHORITY = 3      -- an actor made on this machine (not one the host sent)

local stats = { levelsSent = 0, levelsTaken = 0, given = 0, standIns = 0, hidden = 0, shown = 0 }

--------------------------------------------------------------------------
-- Shared
--------------------------------------------------------------------------

local function placeOf(actor)
    local v = nil
    pcall(function() v = UE.vec(actor:K2_GetActorLocation()) end)
    return v
end

local function distance(a, b)
    if not (a and b) then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function nameOf(actor)
    local n = nil
    pcall(function() n = actor:GetFName():ToString() end)
    return n
end

local function attached(actor)
    local parent = nil
    pcall(function() parent = actor:GetAttachParentActor() end)
    return UE.valid(parent)
end

local function roleOf(actor) return tonumber(UE.TryGet(actor, "Role")) end

local function machineNear(cls, loc)
    local best, bestD = nil, NEAR
    for _, m in ipairs(UE.findAll(cls) or {}) do
        if UE.alive(m) then
            local d = distance(placeOf(m), loc)
            if d < bestD then best, bestD = m, d end
        end
    end
    return best
end

local function levelOf(m) return tonumber(UE.TryGet(m, LEVEL)) end

--- Bring a popcorn machine's level to `want` the machine's own way (its pile
--- grows or shrinks, its outline follows: Update Popcorn Fillness, by the change).
local function setLevel(m, want)
    local cur = levelOf(m)
    if not cur or math.abs(want - cur) < 0.004 then return false end
    return (UE.TryCall(m, "Update Popcorn Fillness", want - cur))
end

--- A product as {kind, fill, flavour}, or nil.
local function describe(item)
    local p = PRODUCTS[UE.ClassNameOf(item) or ""]
    if not p then return nil end
    return { p = p, fill = tonumber(UE.TryGet(item, FILL)) or 0.0,
             flavour = p.flavour and tonumber(UE.TryGet(item, p.flavour)) or 0 }
end

--- Show a product as full and of the flavour given, the product's own way.
local function dress(item, p, fill, flavour)
    local changed = false
    if p.setFlavour and flavour and tonumber(UE.TryGet(item, p.flavour)) ~= flavour then
        -- The property as well: a cotton candy's Set Color only paints it
        -- (the machine writes Color itself, CottonCandyMachine @5896), and a
        -- customer who wants blue checks Color.
        UE.TrySet(item, p.flavour, flavour)
        pcall(function() item[p.setFlavour](item, flavour) end)
        changed = true
    end
    local cur = tonumber(UE.TryGet(item, FILL)) or 0.0
    if math.abs(cur - fill) >= 0.01 then
        UE.TrySet(item, FILL, 0.0)
        pcall(function() item[p.fill](item, fill) end)
        changed = true
    end
    return changed
end

--- What hangs on a pawn's hand socket (replication puts it there), or nil.
local function heldBy(pawn)
    local socket = UE.TryGet(pawn, "AttachObject Socket")
    if not UE.valid(socket) then return nil end
    local n = 0
    pcall(function() n = socket:GetNumChildrenComponents() end)
    for i = 0, (tonumber(n) or 0) - 1 do
        local owner = nil
        pcall(function() owner = socket:GetChildComponent(i):GetOwner() end)
        if UE.alive(owner) and not UE.sameObject(owner, pawn) then return owner end
    end
    return nil
end

local function playerIdOf(pawn)
    local ps = UE.TryGet(pawn, "PlayerState")
    return UE.valid(ps) and tonumber(UE.TryGet(ps, "PlayerId")) or nil
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local hostNext, lastSig, lastAt = 0, nil, 0
local givenAt = {}            -- guest controller name -> when it was last given something

function Conc.tickHost(now)
    if not UE.IsServer() or now < hostNext then return end
    hostNext = now + SEND_EVERY
    if not Chan.isReady() then return end
    local fields, sig = {}, {}
    local n = 0
    for _, m in ipairs(UE.findAll(POPCORN) or {}) do
        local name, v = UE.alive(m) and nameOf(m) or nil, levelOf(m)
        if name and v then
            n = n + 1
            fields["m" .. n], fields["v" .. n] = name, ("%.3f"):format(v)
            sig[#sig + 1] = name .. "=" .. fields["v" .. n]
        end
    end
    fields.n = tostring(n)
    -- Products standing loose (in a machine) and in players' hands.
    local k, h = 0, 0
    for cls, p in pairs(PRODUCTS) do
        for _, item in ipairs(UE.findAll(cls) or {}) do
            if UE.alive(item) and not attached(item) then
                local at, d = placeOf(item), describe(item)
                if at and d then
                    k = k + 1
                    fields["c" .. k] = ("%d;%.0f,%.0f,%.0f;%.3f;%d"):format(p.kind, at.X, at.Y, at.Z, d.fill, d.flavour)
                    sig[#sig + 1] = fields["c" .. k]
                end
            end
        end
    end
    for _, pawn in ipairs(UE.findAll("Player_Character_C") or {}) do
        local item = UE.alive(pawn) and UE.TryGet(pawn, "Object Hold") or nil
        local d = UE.alive(item) and describe(item) or nil
        local id = d and playerIdOf(pawn) or nil
        if id then
            h = h + 1
            fields["h" .. h] = ("%d;%d;%.3f;%d"):format(id, d.p.kind, d.fill, d.flavour)
            sig[#sig + 1] = fields["h" .. h]
        end
    end
    fields.k, fields.h = tostring(k), tostring(h)
    if n + k + h == 0 then return end
    local s = table.concat(sig, ";")
    if s ~= lastSig or (now - lastAt) > RESEND then
        if Chan.broadcast("conc", fields) > 0 then
            lastSig, lastAt = s, now
            stats.levelsSent = stats.levelsSent + 1
        end
    end
end

local function spawnAt(path, loc)
    local gs, w = UE.GetGameplayStatics(), UE.GetWorld()
    local cls = UE.staticFind(path)
    if not UE.valid(cls) and LoadAsset then pcall(function() cls = LoadAsset(path) end) end
    if not (UE.valid(gs) and UE.valid(w) and UE.valid(cls)) then return nil end
    local xform = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                    Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
                    Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local a = nil
    -- AlwaysSpawn (1): it goes straight into a hand.
    pcall(function() a = gs:BeginDeferredActorSpawnFromClass(w, cls, xform, 1, nil, 0) end)
    if not UE.valid(a) then return nil end
    pcall(function() gs:FinishSpawningActor(a, xform, 0) end)
    return UE.valid(a) and a or nil
end

--- A guest's game handed it a product: make a real one, in its hands.
local function give(pc, pawn, p, fill, flavour)
    local key = pc:GetFullName()
    local now = os.clock()
    if givenAt[key] and (now - givenAt[key]) < GIVE_ONCE then return end
    givenAt[key] = now
    local at = placeOf(pawn)
    if not at then return end
    local item = spawnAt(p.class, { X = at.X, Y = at.Y, Z = at.Z + 40.0 })
    if not item then
        Log.warn("concessions: could not make %s for %s", p.label, UE.PlayerNameOf(pc) or "a guest")
        return
    end
    -- What the machine does to a finished product before it hands it over
    -- (Give Cup to player @5404, Give Cotton Stick to player @4397), on one
    -- no machine is listening to: out of the machine, filled, flavoured,
    -- free to be picked up.
    UE.TrySet(item, "Stocked in Machine", false)
    dress(item, p, fill, flavour)
    UE.TrySet(item, "can be Interact with", true)
    pcall(function() item["Set can be pick up"](item, true, {}) end)
    pcall(function() item:SetActorEnableCollision(true) end)
    local held = require("guestinput").asGuest(pc, function() item:Pickup(pawn) end)
    stats.given = stats.given + 1
    Log.info("concessions: %s made %s - it is in their hands%s", UE.PlayerNameOf(pc) or "a guest", p.label,
             held and "" or " (the pick-up did not run)")
end

--- Host: guest actions 17 and 18 (guestinput.lua routes them here).
function Conc.onGuest(pc, pawn, what, loc, rot)
    if not UE.IsServer() then return end
    local r = UE.rot(rot)
    if not r then return end
    local yaw = r.Yaw % 360.0
    if what == "concFill" then
        local m = machineNear(POPCORN, UE.vec(loc))
        if m and setLevel(m, math.max(0.0, math.min(1.0, yaw / 100.0))) then
            stats.levelsTaken = stats.levelsTaken + 1
        end
    elseif what == "concGive" then
        local kind = math.floor((yaw + 0.5) / KIND_STEP)
        local p = BY_KIND[kind]
        if not p then return end
        local fill = math.max(0.0, math.min(1.0, (yaw - kind * KIND_STEP) / FILL_SPAN))
        give(pc, pawn, p, fill, math.floor((r.Pitch % 360.0) + 0.5))
    end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local reportNext, handsNext, heldNext = 0, 0, 0
local working = nil           -- { at, obj, p, sent } the machine this guest works, while it does
local hidden = {}             -- full names of the host's products hidden here
local described = {}          -- player id -> { kind, fill, flavour } the host says they hold

--- The concession machine this guest's own game sits at, or nil.
local function myMachine()
    local m = require("guestinput").machine()
    if m and m.at and MACHINES[m.name] then return m end
    return nil
end

local function onConc(fields)
    if not UE.IsClient() then return end
    local mine = myMachine()
    for i = 1, tonumber(fields.n) or 0 do
        local name, v = fields["m" .. i], tonumber(fields["v" .. i] or "")
        if name and v then
            for _, m in ipairs(UE.findAll(POPCORN) or {}) do
                if UE.alive(m) and nameOf(m) == name then
                    -- The one this guest is working: its own level is the news.
                    if not (mine and distance(mine.at, placeOf(m)) < 1.0) then setLevel(m, v) end
                end
            end
        end
    end
    -- The host's products standing in machines, as they are there.
    for i = 1, tonumber(fields.k) or 0 do
        local kind, x, y, z, fill, flavour =
            (fields["c" .. i] or ""):match("^(%d+);([%d%.%-]+),([%d%.%-]+),([%d%.%-]+);([%d%.]+);(%d+)$")
        local p = kind and BY_KIND[tonumber(kind)]
        if p then
            local at, best, bestD = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, nil, MATCH
            for _, item in ipairs(UE.findAll(p.cls) or {}) do
                if UE.alive(item) and roleOf(item) ~= ROLE_AUTHORITY and not attached(item) then
                    local d = distance(placeOf(item), at)
                    if d < bestD then best, bestD = item, d end
                end
            end
            if best and dress(best, p, tonumber(fill), tonumber(flavour)) then stats.shown = stats.shown + 1 end
        end
    end
    -- What each player holds.
    described = {}
    for i = 1, tonumber(fields.h) or 0 do
        local id, kind, fill, flavour = (fields["h" .. i] or ""):match("^(%-?%d+);(%d+);([%d%.]+);(%d+)$")
        if id then
            described[tonumber(id)] = { kind = tonumber(kind), fill = tonumber(fill), flavour = tonumber(flavour) }
        end
    end
end

--- The host's products in somebody's hands: as the host says, or full.
local function showHeld()
    for _, pawn in ipairs(UE.findAll("Player_Character_C") or {}) do
        local item = UE.alive(pawn) and heldBy(pawn) or nil
        local p = item and roleOf(item) ~= ROLE_AUTHORITY and PRODUCTS[UE.ClassNameOf(item) or ""] or nil
        if p then
            local d = described[playerIdOf(pawn) or -1]
            if d and d.kind == p.kind then
                if dress(item, p, d.fill, d.flavour) then stats.shown = stats.shown + 1 end
            elseif dress(item, p, 1.0, nil) then
                stats.shown = stats.shown + 1
            end
        end
    end
    -- In anybody else's hands (a customer's): full - they only leave a machine so.
    for cls, p in pairs(PRODUCTS) do
        for _, item in ipairs(UE.findAll(cls) or {}) do
            if UE.alive(item) and roleOf(item) ~= ROLE_AUTHORITY and attached(item)
                    and (tonumber(UE.TryGet(item, FILL)) or 0) < 0.99 then
                local parent = nil
                pcall(function() parent = item:GetAttachParentActor() end)
                if UE.ClassNameOf(parent) ~= "Player_Character_C" and dress(item, p, 1.0, nil) then
                    stats.shown = stats.shown + 1
                end
            end
        end
    end
end

local function report(at, v)
    if Chan.sendAction(ACTION_FILL, at, { Pitch = 0.0, Yaw = v * 100.0, Roll = 0.0 }) > 0 then
        working.sent = v
    end
end

--- The host's products standing in this machine: hidden here while the
--- guest works it (its own stand in the same spots), shown again after.
local function hideHostProducts(at, hide)
    for cls in pairs(PRODUCTS) do
        for _, item in ipairs(UE.findAll(cls) or {}) do
            if UE.alive(item) and roleOf(item) ~= ROLE_AUTHORITY then
                local key = nil
                pcall(function() key = item:GetFullName() end)
                if key and hide and not attached(item) and distance(placeOf(item), at) < IN_MACHINE
                        and not hidden[key] then
                    pcall(function() item:SetActorHiddenInGame(true) end)
                    hidden[key] = true
                    stats.hidden = stats.hidden + 1
                elseif key and not hide and hidden[key] then
                    pcall(function() item:SetActorHiddenInGame(false) end)
                    hidden[key] = nil
                end
            end
        end
    end
    if not hide then hidden = {} end
end

--- A product the guest's own game put in its hands: put away, made for real
--- on the host.
local function checkHands()
    local pawn = UE.GetPawn()
    if not UE.alive(pawn) then return end
    local hold = UE.TryGet(pawn, "Object Hold")
    if not UE.alive(hold) then return end
    local d = describe(hold)
    -- Only one made HERE: the host's arrives over the network, and is the real one.
    if not d or roleOf(hold) ~= ROLE_AUTHORITY then return end
    local at = placeOf(pawn)
    if not at then return end
    local yaw = d.p.kind * KIND_STEP + math.max(0.0, math.min(1.0, d.fill)) * FILL_SPAN
    local sent = Chan.sendAction(ACTION_GIVE, at, { Pitch = d.flavour or 0, Yaw = yaw, Roll = 0.0 })
    pcall(function() pawn["Set Object Hold"](pawn, nil) end)
    pcall(function() hold:K2_DestroyActor() end)
    stats.standIns = stats.standIns + 1
    Log.info("concessions: %s made - %s", d.p.label,
             sent > 0 and "the host is putting the real one in your hands" or "COULD NOT REACH THE HOST")
end

function Conc.tickGuest(now)
    if not UE.IsClient() then return end
    if now >= handsNext then
        handsNext = now + HANDS_EVERY
        checkHands()
    end
    if now >= heldNext then
        heldNext = now + HELD_EVERY
        showHeld()
    end
    local mine = myMachine()
    if mine then
        if not (working and distance(working.at, mine.at) < 1.0) then
            working = { at = mine.at, obj = mine.obj, popcorn = mine.name == POPCORN, sent = nil }
            hideHostProducts(mine.at, true)
        end
        if working.popcorn and now >= reportNext then
            reportNext = now + REPORT_EVERY
            local v = UE.alive(mine.obj) and levelOf(mine.obj) or nil
            if v and (working.sent == nil or math.abs(v - working.sent) > 0.004) then report(mine.at, v) end
        end
    elseif working then
        -- Up from the machine: the level as it was left, then the host's products back.
        if working.popcorn then
            local v = UE.alive(working.obj) and levelOf(working.obj) or nil
            if v and (working.sent == nil or math.abs(v - working.sent) > 0.004) then report(working.at, v) end
        end
        hideHostProducts(working.at, false)
        working = nil
    end
end

--------------------------------------------------------------------------

function Conc.report()
    return { ("Concessions: host sent %d update(s), took %d level(s) from guests, made %d product(s); "
              .. "guest put away %d stand-in(s), hid %d of the host's, showed %d as on the host")
              :format(stats.levelsSent, stats.levelsTaken, stats.given, stats.standIns, stats.hidden, stats.shown) }
end

function Conc.reset()
    hostNext, lastSig, lastAt, givenAt = 0, nil, 0, {}
    reportNext, handsNext, heldNext, working, hidden, described = 0, 0, 0, nil, {}, {}
end

function Conc.init()
    Chan.on("conc", function(f) Log.guard("concessions", onConc, f) end)
end

-- For the tests.
Conc._stats = function() return stats end
Conc._products = PRODUCTS

return Conc
