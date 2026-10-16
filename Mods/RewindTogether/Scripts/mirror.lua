--[[
    Rewind Together - the host's machine animations, on the guests' copies

    MEASURED (live, 16 Oct 2026, two copies): with machines.lua a guest works
    the return desk on the host - tray, scanner, rewinder, the drag that shuts
    its door, the tape back in its case - and every step lands. But the guest
    saw almost none of it: the desk's screen kept "SCAN A MOVIE TO BEGIN"
    while the host's showed the scan's result, the tape case stayed shut, the
    rewinder's door never moved, the tape never went in. Those are a machine's
    own animations - timelines on components, a material parameter, a skeletal
    case opening - which the engine does not replicate, run by the host's
    copy of the machine only.

    So the host hooks those Blueprint functions, and each call becomes a line
    to the guests: which function, the actor's class and place, the
    arguments. The guest finds its own copy (by class and nearest place: the
    level's machines and the replicated tape cases both stand where the
    host's do) and calls the same function on it. Only functions read off the
    dumps as cosmetic are on the list: timelines, sounds, materials. Each is
    named by its place in the list, never by a string built at run time (the
    UE4SS member-name cache, PROJECT.md).

    Some parts are moved by setting a component directly, which no hook sees:
    the rewinder's door follows the drag (Pick Up Cup Part - Distance Tick),
    its base shakes, the case's tape is re-attached to the door (Attach Tape
    To Door). Those few components are watched instead: their place and
    whether they show, sent when they change, five times a second at most.

    This also shows a guest what the HOST does at those machines.
]]

local Log  = require("log")
local UE   = require("ue")
local Chan = require("rpcchan")

local Mirror = {}

local P = {
    ret      = "/Game/VideoStore/asset/prop/Return/Return.Return_C",
    rewinder = "/Game/VideoStore/asset/prop/Rewinder/Rewinder.Rewinder_C",
    case     = "/Game/VideoStore/asset/prop/vhs/videotape_FullDetail.videotape_FullDetail_C",
    scanner  = "/Game/VideoStore/asset/prop/DropBox/Scanner.Scanner_C",
    dropbox  = "/Game/VideoStore/asset/prop/DropBox/DropBox.DropBox_C",
    phone    = "/Game/VideoStore/asset/prop/Telephone/Telephone.Telephone_C",
}

-- { class path, function, argument kinds } - "b" bool, "n" number. The
-- index into this list is what travels.
local LIST = {
    { P.ret,      "Set Material Frame",                     "n" },     -- the desk's screen (bp/Return.txt @913)
    { P.rewinder, "Toggle Door",                            "b" },
    { P.rewinder, "Toggle Shake Animation",                 "b" },
    { P.rewinder, "Toggle Visilbity of VHS Tape Attached",  "b" },
    { P.case,     "Open Animation",                         "" },
    { P.case,     "Close Animation",                        "" },
    { P.case,     "Move Tape to Rewind",                    "" },
    { P.case,     "Move Tape Out of Rewind",                "" },
    { P.case,     "Move Tape in box",                       "" },
    -- (Error, Animation Time, Error type, Call End Scan Event): the last is
    -- false on a guest - the scan's end is the host's business.
    { P.scanner,  "Flash Scanner Light",                    "bnnb" },
    { P.dropbox,  "Toggle Animation Flap",                  "bn" },
    -- The phone (bp/Telephone.txt). Its calls are the host's (Phone is
    -- Ringning @31219 runs off the host's timer), so a guest never heard it
    -- ring, saw it light up and shake, or saw the handset come up when
    -- somebody answered (measured: the guest answered fine, by ear only).
    { P.phone,    "SFX - Ring",                             "" },
    { P.phone,    "SFX - Stop Ring",                        "" },
    { P.phone,    "Glow Light",                             "b" },
    { P.phone,    "Animation Shaking",                      "b" },
    { P.phone,    "Toggle Interact Icon",                   "b" },
    { P.phone,    "Toggle Phone Pick",                      "b" },
}
-- Components watched by class: { name, "rel" | "world" }. A "world" one is
-- read and put by its world place (its parent changes on the way).
local PARTS = {
    Rewinder_C = { { "SM_Rewinder_SM_Rewinder_Door", "rel" }, { "Mesh_Base", "rel" }, { "Tape TMP", "rel" } },
    videotape_FullDetail_C = { { "Tape", "world" } },
}
local PARTS_EVERY = 0.2
local SEP, MAX_PER_MSG = "\t", 24
local NEAR = 40.0          -- cm: the guest's copy of an actor is the nearest of its class within this

local queue = {}           -- host: lines waiting for the next tick
local partsNext = 0
local partsSent = {}       -- host: key -> the last state sent
local hooked = {}          -- function path -> address hooked
local nextHook = 0
local stats = { sent = 0, played = 0, missed = 0 }

local function argOf(v)
    pcall(function() if type(v) == "userdata" and v.get then v = v:get() end end)
    return v
end

local function encodeArgs(kinds, args)
    local out = {}
    for i = 1, #kinds do
        local k, v = kinds:sub(i, i), args[i]
        if k == "b" then out[i] = (v == true) and "1" or "0"
        else out[i] = ("%.4g"):format(tonumber(v) or 0) end
    end
    return table.concat(out, ",")
end

local function hookAll(now)
    if now < nextHook then return end
    nextHook = now + 5
    for i, e in ipairs(LIST) do
        local path = e[1] .. ":" .. e[2]
        local f = StaticFindObject(path)
        local addr = nil
        if UE.valid(f) then pcall(function() addr = f:GetAddress() end) end
        if addr and hooked[path] ~= addr then
            local index, kinds = i, e[3]
            local ok = pcall(function()
                RegisterHook(path, function(ctx, a1, a2, a3, a4)
                    if not UE.IsServer() or #queue >= 200 then return end
                    local self = ctx
                    pcall(function() self = ctx:get() end)
                    local at = nil
                    pcall(function() at = UE.vec(self:K2_GetActorLocation()) end)
                    if not at then return end
                    queue[#queue + 1] = table.concat({ tostring(index), UE.ClassNameOf(self),
                        ("%.1f,%.1f,%.1f"):format(at.X, at.Y, at.Z),
                        encodeArgs(kinds, { argOf(a1), argOf(a2), argOf(a3), argOf(a4) }) }, SEP)
                end)
            end)
            if ok then hooked[path] = addr end
        end
    end
end

--- One watched component's state, as text: place, rotation, shown.
local function partState(c, mode)
    local loc, rot = nil, nil
    if mode == "world" then
        pcall(function() loc = UE.vec(c:K2_GetComponentLocation()) end)
        pcall(function() rot = UE.rot(c:K2_GetComponentRotation()) end)
    else
        pcall(function() loc = UE.vec(UE.TryGet(c, "RelativeLocation")) end)
        pcall(function() rot = UE.rot(UE.TryGet(c, "RelativeRotation")) end)
    end
    local shown = nil
    pcall(function() shown = c:IsVisible() end)
    if not (loc and rot) then return nil end
    return ("%.1f,%.1f,%.1f;%.1f,%.1f,%.1f;%s"):format(loc.X, loc.Y, loc.Z, rot.Pitch, rot.Yaw, rot.Roll,
                                                      shown == false and "0" or "1")
end

-- A placed machine never moves: its place is read once (every engine call
-- that returns a vector leaks a little in UE4SS 3.0.1 - ue.lua).
local STILL = { Rewinder_C = true }
local placeOf = {}

local function collectParts()
    for cls, list in pairs(PARTS) do
        for _, a in ipairs(UE.findAll(cls) or {}) do
            local name = nil
            pcall(function() name = a:GetFullName() end)
            local place = STILL[cls] and name and placeOf[name] or nil
            if not place then
                local at = nil
                pcall(function() at = UE.vec(a:K2_GetActorLocation()) end)
                place = at and ("%.1f,%.1f,%.1f"):format(at.X, at.Y, at.Z) or nil
                if place and STILL[cls] and name then placeOf[name] = place end
            end
            if place then
                for k, part in ipairs(list) do
                    local c = UE.TryGet(a, part[1])
                    local st = UE.valid(c) and partState(c, part[2]) or nil
                    local key = cls .. "@" .. place .. "#" .. k
                    if st and partsSent[key] ~= st and #queue < 200 then
                        partsSent[key] = st
                        queue[#queue + 1] = table.concat({ "p" .. k, cls, place, st }, SEP)
                    end
                end
            end
        end
    end
end

--- Host, every tick: hook what has loaded; send what was played and moved.
function Mirror.tickHost(now)
    if not UE.IsServer() then return end
    hookAll(now)
    -- Only while it can matter: a guest at a machine, or a tape case out
    -- (somebody is rewinding - the host too, with guests watching).
    if now >= partsNext and Chan.isReady() then
        partsNext = now + PARTS_EVERY
        if require("machines").anySeated() or #(UE.findAll("videotape_FullDetail_C") or {}) > 0 then
            collectParts()
        end
    end
    if #queue == 0 then return end
    if not Chan.isReady() then queue = {} return end
    while #queue > 0 do
        local fields, n = {}, 0
        while #queue > 0 and n < MAX_PER_MSG do
            n = n + 1
            fields["e" .. n] = table.remove(queue, 1)
        end
        fields.n = tostring(n)
        if Chan.broadcast("anim", fields) > 0 then stats.sent = stats.sent + n end
    end
end

local function nearest(cls, at)
    local best, bestD = nil, NEAR
    for _, o in ipairs(UE.findAll(cls) or {}) do
        local v = nil
        pcall(function() v = UE.vec(o:K2_GetActorLocation()) end)
        if v then
            local dx, dy, dz = v.X - at.X, v.Y - at.Y, v.Z - at.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d < bestD then best, bestD = o, d end
        end
    end
    return best
end

--- Guest: one watched component, put as the host's is.
local function applyPart(k, cls, at, st)
    local part = PARTS[cls] and PARTS[cls][k]
    if not part then return end
    local actor = nearest(cls, at)
    if not actor then stats.missed = stats.missed + 1 return end
    local lx, ly, lz, rp, ry, rr, shown =
        st:match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+);([%d%.%-]+),([%d%.%-]+),([%d%.%-]+);([01])$")
    local c = UE.TryGet(actor, part[1])
    if not (lx and UE.valid(c)) then return end
    local loc = { X = tonumber(lx), Y = tonumber(ly), Z = tonumber(lz) }
    local rot = UE.rotArg({ Pitch = tonumber(rp), Yaw = tonumber(ry), Roll = tonumber(rr) })
    pcall(UE.withHit, function(hit)
        if part[2] == "world" then
            c:K2_SetWorldLocationAndRotation(loc, rot, false, hit, true)
        else
            c:K2_SetRelativeLocationAndRotation(loc, rot, false, hit, true)
        end
    end)
    pcall(function() c:SetVisibility(shown == "1", false) end)
    stats.played = stats.played + 1
end

local function play(line)
    local pk, pcls, px, py, pz, pst = line:match("^p(%d+)\t([%w_%-]+)\t([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)\t(.*)$")
    if pk then
        return applyPart(tonumber(pk), pcls, { X = tonumber(px), Y = tonumber(py), Z = tonumber(pz) }, pst)
    end
    local i, cls, x, y, z, args =line:match("^(%d+)\t([%w_%-]+)\t([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)\t(.*)$")
    local e = LIST[tonumber(i or "")]
    if not (e and cls) then return end
    local actor = nearest(cls, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
    if not actor then stats.missed = stats.missed + 1 return end
    local values, k = {}, 0
    for v in (args .. ","):gmatch("([^,]*),") do
        k = k + 1
        local kind = e[3]:sub(k, k)
        if kind == "b" then values[k] = (v == "1") elseif kind == "n" then values[k] = tonumber(v) or 0 end
    end
    if e[2] == "Flash Scanner Light" then values[4] = false end
    local fn = e[2]      -- a literal from LIST, never the message's text
    if pcall(function() actor[fn](actor, table.unpack(values, 1, #e[3])) end) then
        stats.played = stats.played + 1
    end
end

local function onAnim(fields)
    if not UE.IsClient() then return end
    for j = 1, tonumber(fields.n) or 0 do
        local line = fields["e" .. j]
        if line then play(line) end
    end
end

function Mirror.report()
    return { ("Machine animations: %d sent; guest: %d played, %d without a copy here"):format(
        stats.sent, stats.played, stats.missed) }
end

function Mirror.reset()
    queue, partsSent, partsNext, placeOf = {}, {}, 0, {}
end

function Mirror.init()
    Chan.on("anim", function(f) Log.guard("machine animations", onAnim, f) end)
end

-- For the tests.
Mirror._play, Mirror._queue = play, function() return queue end

return Mirror
