--[[
    Rewind Together - the repair desk and the console rental, for guests

    REQUESTED (16 Oct 2026): the follow-up to the store's screen machines
    (uimachines.lua): "make the repair desk's minigame and the console rental
    work for guests". Read off the dumps (RepairStation, Cartridge_Base,
    ConsoleRental_Station, _Mat, _Console-Base; docs/MULTIPLAYER-AUDIT.md):

      * THE REPAIR DESK. A broken tape is one whose Error is 5, and Error is
        not replicated (Cartridge_Base: only "Product Structure" is): tapes
        break on the host, at the scanner or in its save. So a guest's own
        desk always said "not a broken cartridge" (Interaction @695, @1340)
        and never started. The repair itself is a minigame on the player's
        own screen - zones hit-tested from the local cursor, tools that
        follow the local mouse, a tape model spawned on the desk (@0-@1600,
        the tool ticks) - which the host cannot play for anybody. So the
        guest's game plays it, on its own desk, as in single player: the
        host says which state the tape in each guest's hand is in ("rph"),
        the guest's copy of that tape is given it (and is put in the pawn's
        "Object Hold", which the desk reads), and the desk takes it. When the
        guest's desk finishes (Repair cartridge End, @0-@2276: the tape
        fixed, back in the hand) the guest says so (action 24), and the
        host does to the REAL tape - still in that guest's hand on the host,
        it never left it there - what the end of a repair does: Error 1, the
        broken sticker off (@582, @621), and the 2 XP its pick-up gives
        (Pickup The Container @434). The Steam stat (@1438) counts only where
        a GameMode is (Is Achievement Allowed): on a guest, not at all.
        A guest who walks away mid-repair gets the tape back in the hand
        (the desk's own Destroy The Video Tape Repair Detail and Pickup The
        Container): in single player it would wait on the desk, but on the
        host it never left the guest's hand, and both must agree.
      * THE CONSOLE RENTAL. The mat and the station are worked by clicks in
        the world, which the host replays as the guest (guestinput.lua; the
        mat is never "sat at", its Interaction never calls Toggle Machine).
        What a guest's copies lacked is the host's state: each console's
        State and "is Broken" (not replicated; the save loads them on the
        host only), so a guest's own slot could take a console the host
        refused; the monitor (Status For Monitor, the scan's progress bar),
        and the slot lights. The host sends them ("crs"). A guest's console
        copies are always given State 1 ("scan in progress"), which the
        guest's own slots (they take 0) and mat (it takes 2) both refuse, so
        only the host's replay of the click does the work and replication
        brings the result. MEASURED (16 Oct 2026): with the host's State 0
        on the guest's copy, the guest's own shelf took the console at the
        same click as the host's, and the two then held it apart.
        The stickers and the mat's drawers come through mirror.lua.
      * THE CUSTOMER'S CONSOLE CASE. A customer renting a console has an
        open case put on the counter for it (NeedHelp Create a case and
        Play Animation - Set on Counter A Case, from BTTask_ConsoleRent-
        Asking @13339), the console goes in, the case shuts, and the
        customer carries it out (Request-QuestZone_ConsoleRental, Make
        Client to pickup case). The case is a plain Actor, not replicated:
        a guest had an empty counter to put the console on, and saw the
        customer leave empty-handed. The host has the engine send it
        (Replication.patchActor), and its lid with the console rental
        ("crs"): the lid is a component turned by a timeline, which the
        engine does not send. Only the counter's case - the help desk's own
        "Case Slot", which Create a case fills: every customer also carries
        one of its own, hidden (AI_Client_Character's "ConsoleRent-Case", a
        child actor), which every machine builds for itself. MEASURED (16
        Oct 2026): sending those as well gave a guest a second case floating
        at every customer's side, and filled the lid list. Telling them
        apart by GetParentActor let 56 of them through: a child actor is
        not yet linked to its parent when it appears.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")
local Replication = require("replication")

local Repairs = {}

local ACTION_REPAIRED = 24
local BROKEN, FIXED = 5, 1                   -- Scanner_ErrorType (Interaction @695, Repair cartridge End @582)
local REPAIR_XP = 2                          -- Pickup The Container @434
local OP_HOST  = "a guest's repair or the console rental on the host"
local OP_GUEST = "the repair desk and the console rental on a guest"

local CART    = "/Game/VideoStore/asset/prop/vhs/Cartridge_Base.Cartridge_Base_C"
local CONSOLE = "/Game/VideoStore/asset/prop/ConsoleRental/ConsoleRental_Console-Base.ConsoleRental_Console-Base_C"
local REPAIR_END = "/Game/VideoStore/asset/prop/RepairStation/RepairStation.RepairStation_C:Repair cartridge End"
local SLOT = "RepairStation-Shelve_Container"
local SLOT_OWNER = "Object owning of this container"
-- The product's name in its Product_Structure (as the HUD reads it).
local PRODUCT_NAME = { "BaseStructure_2_FBB12C464AE570CAFD12ED8506160683", "BoxData_25_B5A798DA4F509BDCCF4B189171C1DA10",
                       "ProductName_14_055828B1436E5AD27BFA95AF181099DE" }
local SLOTS = 8                              -- ConsoleRental_Container0..7
local CASE = "ConsoleRent-Case_C"
local CASE_PATH = "/Game/VideoStore/asset/prop/ConsoleRent-Case/ConsoleRent-Case.ConsoleRent-Case_C"
local CASE_LID = "Case Top"                  -- its Roll is the lid's angle (Set Animation of Case Top Angle @722-@798)

local HELD_EVERY  = 0.5
local HELD_RESEND = 5.0
local CRS_EVERY   = 0.5
local CRS_RESEND  = 10.0
local RETRY_AFTER = 4.0
local SEEN_FOR    = 15.0
local REPAIRED_FOR = 10.0                    -- guest: a tape it just fixed is not broken again on an old word
local NEAR = 40.0
local MAX_CONSOLES = 16
local MAX_CASES = 4
local CASE_EVERY = 1.0

local stats = { heldSent = 0, repaired = 0, refused = 0, marked = 0, finished = 0, handedBack = 0,
                crsSent = 0, monitor = 0, lights = 0, consoles = 0, settled = 0, casesShared = 0, lids = 0 }

--------------------------------------------------------------------------
-- Shared
--------------------------------------------------------------------------

local function round(v) return math.floor((tonumber(v) or 0) + 0.5) end

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

local function get(s, k)
    local v = nil
    if s ~= nil then pcall(function() v = s[k] end) end
    return v
end

local function isA(o, path)
    local cls = StaticFindObject(path)
    if not (UE.alive(o) and UE.valid(cls)) then return false end
    local ok, yes = pcall(function() return o:IsA(cls) end)
    return ok and yes == true
end

local function productOf(tape)
    local s = UE.TryGet(tape, "Product Structure")
    for _, k in ipairs(PRODUCT_NAME) do s = get(s, k) end
    local n = nil
    if s ~= nil then pcall(function() n = s:ToString() end) end
    return type(n) == "string" and n or ""
end

local function heldTape(pawn)
    local h = UE.TryGet(pawn, "Object Hold")
    return isA(h, CART) and h or nil
end

local function widgetOf(c)
    if not UE.valid(c) then return nil end
    local ok, w = UE.TryCall(c, "GetUserWidgetObject")
    return (ok and UE.valid(w)) and w or nil
end

local function placeOf(a)
    local v = nil
    pcall(function() v = UE.vec(a:K2_GetActorLocation()) end)
    return v
end

--- Host: the console case on the counter, the help desk's own (see the top).
local function counterCase()
    local ag = UE.TryGet(UE.GetGameMode(), "Actor Gatherer")
    local nh = ag and UE.TryGet(ag, "NeedHelp") or nil
    local c = UE.alive(nh) and UE.TryGet(nh, "Case Slot") or nil
    return UE.alive(c) and c or nil
end

--- Guest: the console cases that are not a customer's own (those are child
--- actors, linked by now).
local function looseCases()
    local list = {}
    for _, c in ipairs(UE.findAll(CASE) or {}) do
        local parent = nil
        if UE.alive(c) then pcall(function() parent = c:GetParentActor() end) end
        if UE.alive(c) and not UE.valid(parent) then list[#list + 1] = c end
    end
    return list
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local heldSent = {}        -- host: pc full name -> { sig, at }
local seen = {}
local nextHeld, nextCrs, nextCase = 0, 0, 0
local crsSig, crsAt = nil, -1e9

local function tell(pc, ok, text)
    Chan.sendTo(pc, "rpres", { ok = ok and "1" or "0", t = text or "" })
    if not ok then stats.refused = stats.refused + 1 end
end

--- Each guest: the state of the tape in its hand, as the host has it.
local function sendHeld(now)
    if now < nextHeld then return end
    nextHeld = now + HELD_EVERY
    for _, pc in ipairs(UE.GetAllPlayerControllers() or {}) do
        if UE.alive(pc) and not UE.IsLocalController(pc) then
            local tape = heldTape(UE.TryGet(pc, "Pawn"))
            local e = tape and round(UE.TryGet(tape, "Error")) or -1
            local p = tape and productOf(tape) or ""
            local sig = e .. "|" .. p
            local name = pc:GetFullName()
            local last = heldSent[name]
            if not last or last.sig ~= sig or (tape and (now - last.at) > HELD_RESEND) then
                if Chan.sendTo(pc, "rph", { e = tostring(e), p = p }) then
                    heldSent[name] = { sig = sig, at = now }
                    stats.heldSent = stats.heldSent + 1
                end
            end
        end
    end
end

local function asGuest(pc, fn) return require("guestinput").asGuest(pc, fn) end

--- A guest's desk fixed the tape in its hand: the host's tape, the same way.
local function repaired(pc)
    local pawn = UE.TryGet(pc, "Pawn")
    local tape = heldTape(pawn)
    if not tape then return tell(pc, false, "The host does not see a tape in your hands.") end
    if round(UE.TryGet(tape, "Error")) ~= BROKEN then return tell(pc, true, "Repaired.") end
    local desk = UE.findFirst("RepairStation_C")
    local gm = UE.GetGameMode()
    asGuest(pc, function()
        tape["Set Error"](tape, UE.alive(desk) and desk or tape, FIXED)
        tape["Toggle Broken Sticker"](tape, false)
        if UE.valid(gm) then
            local out = {}
            UE.TryCall(gm, "Change XP", REPAIR_XP, out)
            UE.releaseOut(out)
        end
    end)
    if round(UE.TryGet(tape, "Error")) ~= FIXED then return tell(pc, false, "The repair did not go through.") end
    stats.repaired = stats.repaired + 1
    heldSent[pc:GetFullName()] = nil
    Log.info("repair desk: %s repaired %s", UE.PlayerNameOf(pc) or "a guest", productOf(tape))
    tell(pc, true, "Repaired - the tape is as good as new.")
end

--- Host: guest action 24 (guestinput.lua routes it here), numbered in Pitch.
function Repairs.onGuest(pc, pawn, loc, rot)
    if not UE.IsServer() or not UE.valid(pc) then return end
    local now = os.clock()
    local key = pc:GetFullName() .. "#" .. round(rot and rot.Pitch)
    for k, t in pairs(seen) do if now - t > SEEN_FOR then seen[k] = nil end end
    if seen[key] then return end
    seen[key] = now
    Safety.guard(OP_HOST, repaired, pc)
end

--- The console rental as the host has it: the monitor, the slot lights and
--- every console's State and broken flag.
local function sendCrs(now)
    if now < nextCrs then return end
    nextCrs = now + CRS_EVERY
    local st = UE.findFirst("ConsoleRental_Station_C")
    if not (UE.alive(st) and UE.TryGet(st, "Bought") == true) then return end
    local w = widgetOf(UE.TryGet(st, "Monitor_Widget"))
    local bar = false
    local div = w and UE.TryGet(w, "DIV_Progression") or nil
    if UE.valid(div) then pcall(function() bar = div:IsVisible() end) end
    local lights = {}
    for i = 0, SLOTS - 1 do
        local c = UE.TryGet(st, "ConsoleRental_Container" .. i)
        lights[#lights + 1] = (UE.valid(c) and UE.alive(UE.TryGet(c, SLOT_OWNER))) and "1" or "0"
    end
    local fields = { s = tostring(round(UE.TryGet(st, "Current Monitor Step"))),
                     f = tostring(round(UE.TryGet(st, "Current Error Frame"))),
                     p = ("%.2f"):format(tonumber(UE.TryGet(st, "Scanning Progression")) or 0),
                     b = bar and "1" or "0", l = table.concat(lights) }
    local n = 0
    for _, c in ipairs(UE.findAll("ConsoleRental_Console-Base_C") or {}) do
        local at = UE.alive(c) and placeOf(c) or nil
        if at and n < MAX_CONSOLES then
            n = n + 1
            local r = nil
            pcall(function() r = UE.rot(c:K2_GetActorRotation()) end)
            fields["c" .. n] = ("%.1f,%.1f,%.1f,%.1f,%d,%d"):format(at.X, at.Y, at.Z, r and r.Yaw or 0,
                                                                   round(UE.TryGet(c, "State")),
                                                                   UE.TryGet(c, "is Broken") == true and 1 or 0)
        end
    end
    fields.n = tostring(n)
    local k = 0
    for _, c in ipairs({ counterCase() }) do
        local at = placeOf(c)
        local lid = at and UE.TryGet(c, CASE_LID) or nil
        local r = UE.valid(lid) and UE.rot(UE.TryGet(lid, "RelativeRotation")) or nil
        if r and k < MAX_CASES then
            k = k + 1
            fields["k" .. k] = ("%.1f,%.1f,%.1f,%.0f"):format(at.X, at.Y, at.Z, r.Roll)
        end
    end
    fields.k = tostring(k)
    -- Places move a little while a console is carried: the signature leaves them out.
    local parts = { fields.s, fields.f, fields.p, fields.b, fields.l }
    for i = 1, n do parts[#parts + 1] = fields["c" .. i]:match("(%d+,%d+)$") end
    for i = 1, k do parts[#parts + 1] = fields["k" .. i]:match("(%-?%d+)$") end
    local sig = table.concat(parts, "|")
    if sig == crsSig and (now - crsAt) < CRS_RESEND then return end
    if Chan.broadcast("crs", fields) > 0 then
        crsSig, crsAt = sig, now
        stats.crsSent = stats.crsSent + 1
    end
end

--- The customers' console cases, sent by the engine (see the top).
local function shareCases(now)
    if now < nextCase then return end
    nextCase = now + CASE_EVERY
    local c = counterCase()
    if c and Replication.patchActor(c) then stats.casesShared = stats.casesShared + 1 end
end

function Repairs.tickHost(now)
    if not UE.IsServer() or UE.IsStandalone() or not Chan.isReady() then return end
    sendHeld(now)
    shareCases(now)
    sendCrs(now)
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local held = nil           -- guest: { e, p } - the host's word on the tape in our hand
local repairedAt = {}      -- guest: tape address -> until when it is ours as fixed
local putHold = nil        -- guest: the tape we put in the pawn's Object Hold (the desk reads it)
local finished = {}        -- guest: from the hook
local pending = nil
local seq = 0
local hookedAt = nil
local nextHook = 0
local desk = { busy = false, since = nil, done = false }
local crs = nil            -- guest: the host's console rental
local shown = {}           -- guest: what the guest's station shows now

local function hookEnd(now)
    if now < nextHook then return end
    nextHook = now + 5
    local f = StaticFindObject(REPAIR_END)
    local addr = UE.valid(f) and addressOf(f) or nil
    if not addr or hookedAt == addr then return end
    local ok = pcall(function()
        RegisterHook(REPAIR_END, function(ctx)
            if not UE.IsClient() or #finished >= 4 then return end
            local d = nil
            pcall(function() d = ctx:get() end)
            local slot = UE.valid(d) and UE.TryGet(d, SLOT) or nil
            local tape = UE.valid(slot) and UE.TryGet(slot, SLOT_OWNER) or nil
            finished[#finished + 1] = UE.alive(tape) and addressOf(tape) or 0
        end)
    end)
    if ok then hookedAt = addr end
end

local function send(o)
    return Chan.sendAction(ACTION_REPAIRED, { X = 1, Y = 0, Z = 0 }, { Pitch = o.seq, Yaw = 0, Roll = 0 }) > 0
end

--- What replication has put in the pawn's hand (hud.lua's reading).
local function inHand(pawn)
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

local function setHold(pawn, o)
    return pcall(function() pawn["Set Object Hold"](pawn, o) end)
end

--- The guest's desk: the host's word on the tape in the hand, written on
--- the guest's copy - and that tape in the pawn's Object Hold, where the
--- desk looks for it.
local function markHeld(now, pawn, d)
    local tape = inHand(pawn)
    if not isA(tape, CART) then tape = nil end
    -- A tape we put in Object Hold has left the hand: let it go there too.
    if putHold and not (tape and UE.sameObject(tape, putHold)) then
        if UE.sameObject(UE.TryGet(pawn, "Object Hold"), putHold) and not desk.busy then setHold(pawn, nil) end
        putHold = nil
    end
    if not (tape and held and held.e >= 0 and productOf(tape) == held.p) then return end
    local a = addressOf(tape)
    local want = held.e
    if want == BROKEN and a and repairedAt[a] and now < repairedAt[a] then return end
    if round(UE.TryGet(tape, "Error")) ~= want and UE.TrySet(tape, "Error", want) then
        stats.marked = stats.marked + 1
    end
    if want == BROKEN and not UE.valid(UE.TryGet(pawn, "Object Hold")) and setHold(pawn, tape) then
        putHold = tape
    end
end

--- Left the desk before the end: the tape back in the hand, as the host has it.
local function watchDesk(now, d)
    local busy = UE.TryGet(d, "In Machine Mode") == true
    if busy then
        if not desk.busy then desk.done = false end
        desk.busy, desk.since = true, nil
        return
    end
    if desk.busy then desk.busy, desk.since = false, now end
    if desk.since and (now - desk.since) > 0.6 then
        desk.since = nil
        local slot = UE.TryGet(d, SLOT)
        if not desk.done and UE.valid(slot) and UE.alive(UE.TryGet(slot, SLOT_OWNER)) then
            UE.TryCall(d, "Destroy The Video Tape Repair Detail")
            UE.TryCall(d, "Pickup The Container")
            stats.handedBack = stats.handedBack + 1
            Log.info("repair desk: left mid-repair - the tape is back in your hands")
        end
    end
end

local function takeFinished(now)
    while #finished > 0 do
        local a = table.remove(finished, 1)
        if a ~= 0 then repairedAt[a] = now + REPAIRED_FOR end
        desk.done = true
        stats.finished = stats.finished + 1
        seq = (seq % 80) + 1
        pending = { seq = seq, at = now }
        send(pending)
    end
    for a, t in pairs(repairedAt) do if now > t then repairedAt[a] = nil end end
    if pending and (now - pending.at) > RETRY_AFTER then
        if pending.retried then
            pending = nil
        else
            pending.retried, pending.at = true, now
            send(pending)
        end
    end
end

local function nearest(cls, at, list)
    local best, bestD = nil, NEAR
    for _, o in ipairs(list or UE.findAll(cls) or {}) do
        local v = placeOf(o)
        if v then
            local dx, dy, dz = v.X - at.X, v.Y - at.Y, v.Z - at.Z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist < bestD then best, bestD = o, dist end
        end
    end
    return best
end

--- The guest's station shows what the host's does.
local function drawStation()
    local st = UE.findFirst("ConsoleRental_Station_C")
    if not (crs and UE.alive(st)) then return end
    local a = addressOf(st)
    if shown.at ~= a then shown = { at = a } end
    local step, frame = tonumber(crs.s) or 0, tonumber(crs.f) or 0
    if shown.s ~= step or shown.f ~= frame then
        -- Force: the guest's own step may already be this one (@5, @207).
        UE.TryCall(st, "Status For Monitor", step, true, frame)
        shown.s, shown.f = step, frame
        stats.monitor = stats.monitor + 1
    end
    local w = widgetOf(UE.TryGet(st, "Monitor_Widget"))
    if w then
        local bar = crs.b == "1"
        if shown.b ~= bar then
            UE.TryCall(w, "Toggle Progression Bar", bar)
            shown.b = bar
        end
        local p = tonumber(crs.p) or 0
        if bar and shown.p ~= p then
            UE.TryCall(w, "Set Progression", p)
            shown.p = p
        end
    end
    local lights = crs.l or ""
    for i = 0, SLOTS - 1 do
        local on = lights:sub(i + 1, i + 1) == "1"
        local key = "l" .. i
        if shown[key] ~= on then
            local c = UE.TryGet(st, "ConsoleRental_Container" .. i)
            if UE.valid(c) and UE.TryCall(st, "Set A Container Light", c, on) then
                shown[key] = on
                stats.lights = stats.lights + 1
            end
        end
    end
end

--- A guest's copy whose mesh has left its root: its own "Verify if the
--- console is stored somewhere" runs 20 s after it appears, finds none of its
--- guards hold on a guest, lifts it and turns its physics on (@209, @249) -
--- and a simulating mesh leaves its root (thrown.lua). MEASURED (16 Oct 2026):
--- a VHS player the host had put on the mat was still on the guest's floor at
--- the delivery spot. Its own Toggle Simulate Physic(false) puts the root on
--- the mesh again; then the actor goes where the host's is.
local function settle(c, at, yaw)
    local m = UE.TryGet(c, "Mesh")
    local here = placeOf(c)
    local mw = nil
    if UE.valid(m) then pcall(function() mw = UE.vec(m:K2_GetComponentLocation()) end) end
    if not (here and mw) then return end
    local dx, dy, dz = mw.X - here.X, mw.Y - here.Y, mw.Z - here.Z
    if math.sqrt(dx * dx + dy * dy + dz * dz) < 5.0 then return end
    UE.TryCall(c, "Toggle Simulate Physic", false)
    pcall(UE.withHit, function(hit)
        c:K2_SetActorLocationAndRotation(at, UE.rotArg({ Pitch = 0, Yaw = yaw, Roll = 0 }), false, hit, true)
    end)
    stats.settled = stats.settled + 1
end

--- Each console's copy: State 1 whatever the host's is (see the top), and
--- the host's broken flag.
local function markConsoles()
    if not crs then return end
    for i = 1, math.min(tonumber(crs.n) or 0, MAX_CONSOLES) do
        local x, y, z, yaw, _, b = (crs["c" .. i] or ""):match(
            "^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),(%d+),([01])$")
        local at = x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } or nil
        local c = at and nearest("ConsoleRental_Console-Base_C", at) or nil
        if c then
            settle(c, at, tonumber(yaw) or 0)
            local want = 1                 -- never one the guest's own slot or mat would take
            local broken = b == "1"
            if round(UE.TryGet(c, "State")) ~= want then
                UE.TrySet(c, "State", want)
                stats.consoles = stats.consoles + 1
            end
            if (UE.TryGet(c, "is Broken") == true) ~= broken then UE.TrySet(c, "is Broken", broken) end
        end
    end
end

--- Each case's lid as the host's is.
local function markCases()
    if not crs or (tonumber(crs.k) or 0) == 0 then return end
    for i = 1, math.min(tonumber(crs.k) or 0, MAX_CASES) do
        local x, y, z, roll = (crs["k" .. i] or ""):match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
        local at = x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } or nil
        local c = at and nearest(CASE, at, looseCases()) or nil
        local lid = c and UE.TryGet(c, CASE_LID) or nil
        local cur = UE.valid(lid) and UE.rot(UE.TryGet(lid, "RelativeRotation")) or nil
        local want = tonumber(roll)
        if cur and want and math.abs(cur.Roll - want) > 1.0 then
            pcall(UE.withHit, function(hit)
                lid:K2_SetRelativeRotation(UE.rotArg({ Pitch = 0, Yaw = 0, Roll = want }), false, hit, true)
            end)
            stats.lids = stats.lids + 1
        end
    end
end

local nextLook = 0

function Repairs.tickGuest(now)
    if not UE.IsClient() then return end
    hookEnd(now)
    takeFinished(now)
    if now < nextLook then return end
    nextLook = now + 0.25
    Safety.guard(OP_GUEST, function()
        local pawn = UE.GetPawn()
        local d = UE.findFirst("RepairStation_C")
        if UE.alive(d) then watchDesk(now, d) end
        if UE.alive(pawn) and UE.ClassNameOf(pawn) == "Player_Character_C" and not desk.busy then
            markHeld(now, pawn, d)
        end
        drawStation()
        markConsoles()
        markCases()
    end)
end

local function onHeld(f)
    if not UE.IsClient() then return end
    held = { e = tonumber(f.e) or -1, p = f.p or "" }
end

local function onCrs(f)
    if not UE.IsClient() then return end
    crs = f
end

local function onResult(f)
    if not UE.IsClient() then return end
    local ok = f.ok == "1"
    pending = nil
    require("hud").notice(f.t ~= "" and f.t or (ok and "Repaired." or "That did not go through."), not ok, 3)
end

function Repairs.report()
    return { ("Repairs: host sent the held tape %d time(s), %d repaired for guests, %d refused, console rental " ..
              "sent %d; guest marked %d tape(s), finished %d repair(s), %d handed back, monitor %d, lights %d, " ..
              "consoles %d (%d put back on their roots); customers' cases sent %d, lids %d%s"):format(
              stats.heldSent, stats.repaired, stats.refused, stats.crsSent, stats.marked,
              stats.finished, stats.handedBack, stats.monitor, stats.lights, stats.consoles, stats.settled,
              stats.casesShared, stats.lids, pending and ", a repair waiting" or "") }
end

function Repairs.reset()
    heldSent, seen, held, repairedAt, putHold, finished, pending = {}, {}, nil, {}, nil, {}, nil
    desk = { busy = false, since = nil, done = false }
    crs, shown, crsSig, crsAt, nextCase = nil, {}, nil, -1e9, 0
    hookedAt = nil
end

function Repairs.init()
    UE.knowClass("ConsoleRental_Console-Base_C", CONSOLE)
    UE.knowClass(CASE, CASE_PATH)
    Chan.on("rph", function(f) Log.guard("the host's word on a tape in hand", onHeld, f) end)
    Chan.on("crs", function(f) Log.guard("the host's console rental", onCrs, f) end)
    Chan.on("rpres", function(f) Log.guard("a repair's answer", onResult, f) end)
end

-- For the tests.
Repairs._stats = function() return stats end

return Repairs
