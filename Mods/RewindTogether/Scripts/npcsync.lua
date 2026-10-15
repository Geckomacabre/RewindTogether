--[[
    Rewind Together - the town's NPCs, host to guest

    REPORTED in 1.7.0's first two-instance session: "the NPCs on the client
    don't have animation or variations". Measured, side by side:

      host   SK_CHA_M_02 / SK_CHA_F_02 ... genre 1/2, Current Task 5, walking
      guest  SK_CHA_M_01 every one of them, genre 0,   Current Task 0

    An NPC's body, clothes and colours are rolled on the HOST when the AI
    Director spawns it, into Blueprint variables and dynamic materials that
    were never meant to replicate. The NPC actor itself does replicate (the mod
    turns that on), so the guest gets a body in the right place, moving - but
    built from the class defaults: the same bald man in grey, over and over.
    Its animation blueprint (AnimBP_Base_C) reads Current Task / Sub Task /
    Pick Up Level / Has Basket / Is Holding something off the character, and
    with all of them at zero it holds the idle pose while the capsule walks.

    So the host sends, per NPC:
      state (twice a second)  position + those five animation inputs + emotion
      look  (once, refreshed) body mesh, hair / facial meshes, and for each
                              clothing slot the material, base-colour texture
                              and tint - read straight off its dynamic
                              materials (8 slots: skin, top, bottom, shoes,
                              hair, mouth, eyes; measured)
    and the guest rebuilds it with the engine's own calls
    (SetSkinnedAssetAndUpdate, CreateDynamicMaterialInstance, Set*ParameterValue)
    - each one tried by hand on a guest NPC first, all accepted.

    MATCHING. Replicated actors do not share names across machines, and the
    network ID that would match them exactly has no reflection data. But their
    POSITIONS replicate, so each host NPC is paired with the nearest unclaimed
    guest NPC of the same class, and the pairing is kept until they drift
    apart. Two NPCs within a step of each other could swap looks; nobody is
    going to file that bug.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local Npc = {}

local CLASSES = {
    W = "AI_WalkBy_Character_C",
    C = "AI_Client_Character_C",
    E = "AI_Employee_Character_C",
    V = "AI_BackAlleyVendor_Character_C",
}
local STATE_EVERY  = 0.5
local LOOK_EVERY   = 15.0     -- per NPC, so a guest who joins late still gets it
local LOOKS_PER_TICK = 3      -- spread the big messages out
local MATCH_RADIUS = 220      -- units; an NPC walks ~165/s, state is 2 Hz
local LOSE_RADIUS  = 600
local PREFIX       = "/Game/VideoStore/asset/character/"
local RESTYLE_OP   = "restyling the town's NPCs on a guest"

local cfg = nil

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function idOf(actor)
    local ok, n = pcall(function() return actor:GetFName():ToString() end)
    return ok and n or nil
end

local function pathOf(o)
    if not UE.valid(o) then return "" end
    local ok, full = pcall(function() return o:GetFullName() end)
    if not ok or type(full) ~= "string" then return "" end
    local p = full:match("^%S+%s+(.+)$") or full     -- drop the "Class " prefix
    if p:sub(1, #PREFIX) == PREFIX then p = "~" .. p:sub(#PREFIX + 1) end
    return p
end

local function expand(p)
    if type(p) ~= "string" or p == "" then return nil end
    if p:sub(1, 1) == "~" then p = PREFIX .. p:sub(2) end
    -- Only this game's own assets; this string came over the network.
    if not p:match("^/Game/[%w_/%.%-]+$") then return nil end
    return p
end

local function num(v, fmt)
    return type(v) == "number" and (fmt or "%d"):format(v) or "0"
end

local function bool01(v) return v == true and "1" or "0" end

--------------------------------------------------------------------------
-- Host: read a look off a live NPC
--------------------------------------------------------------------------

local function readSlot(mesh, i)
    local mat = nil
    pcall(function() mat = mesh:GetMaterial(i) end)
    if not UE.valid(mat) then return "" end
    local parent, tex, tint = "", "", ""
    pcall(function() parent = pathOf(mat.Parent) end)
    if parent == "" then parent = pathOf(mat) end
    pcall(function()
        mat.TextureParameterValues:ForEach(function(_, e)
            local v = e:get()
            if v.ParameterInfo.Name:ToString() == "Base Color" then tex = pathOf(v.ParameterValue) end
        end)
    end)
    pcall(function()
        mat.VectorParameterValues:ForEach(function(_, e)
            local v = e:get()
            local name = v.ParameterInfo.Name:ToString()
            if name == "Tint - Red Channel" then
                local c = v.ParameterValue
                tint = ("%.3f,%.3f,%.3f"):format(UE.field(c, "R") or 0, UE.field(c, "G") or 0, UE.field(c, "B") or 0)
            end
        end)
    end)
    return parent .. "|" .. tex .. "|" .. tint
end

local function readEyes(mesh)
    local out = ""
    pcall(function()
        local mat = mesh:GetMaterial(6)
        mat.VectorParameterValues:ForEach(function(_, e)
            local v = e:get()
            local name = v.ParameterInfo.Name:ToString()
            if name == "Skin Tone" or name == "SSS Skin Tone" then
                local c = v.ParameterValue
                out = out .. ("%s=%.3f,%.3f,%.3f;"):format(name == "Skin Tone" and "s" or "x",
                    UE.field(c, "R") or 0, UE.field(c, "G") or 0, UE.field(c, "B") or 0)
            end
        end)
    end)
    return out
end

local function readLook(npc, id)
    local look = { i = id }
    local mesh = UE.TryGet(npc, "Mesh")
    if not UE.valid(mesh) then return nil end
    pcall(function() look.m = pathOf(mesh.SkeletalMesh) end)
    for key, comp in pairs({ h = "Hair", f = "Facial-Hair", a = "Facial-Accesory" }) do
        local c = UE.TryGet(npc, comp)
        if UE.valid(c) then
            local vis = false
            pcall(function() vis = c:IsVisible() end)
            look[key] = vis and pathOf(UE.TryGet(c, "StaticMesh")) or ""
        end
    end
    for i = 0, 4 do look["s" .. i] = readSlot(mesh, i) end
    look.e = readEyes(mesh)
    return look
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local lastState = 0
local lookSentAt = {}       -- id -> os.clock() when its look last went out

-- All four synced classes share this parent (measured: AI_WalkBy_Character_C >
-- AI_Base_Character_C > Character). One list of it costs one class lookup
-- where four lists cost four (ue.lua: each lookup costs a little memory).
local NPC_BASE = "AI_Base_Character_C"
local CODE_OF = {}
for code, cls in pairs(CLASSES) do CODE_OF[cls] = code end
local codeByClass = {}      -- exact class name -> code, or false: strings only

local function codeOf(npc)
    local cls = nil
    pcall(function() cls = npc:GetClass() end)
    if not UE.valid(cls) then return nil end
    local name = nil
    pcall(function() name = cls:GetFName():ToString() end)
    if not name then return nil end
    local known = codeByClass[name]
    if known ~= nil then return known or nil end
    -- First time this exact class is seen: climb to the synced class it is.
    local code, c = false, cls
    for _ = 1, 8 do
        if not UE.valid(c) then break end
        local n = nil
        pcall(function() n = c:GetFName():ToString() end)
        if n and CODE_OF[n] then code = CODE_OF[n] break end
        local up = nil
        pcall(function() up = c:GetSuperStruct() end)
        c = up
    end
    codeByClass[name] = code
    return code or nil
end

--- Every NPC of a synced class, with its one-letter code.
local function eachNpc(fn)
    local list = UE.findAll(NPC_BASE)
    if list or UE.classKnown(NPC_BASE) then
        for _, npc in ipairs(list or {}) do
            local code = codeOf(npc)
            if code then fn(npc, code) end
        end
        return
    end
    -- The base class is not known yet (or this is the test harness): per class.
    for code, cls in pairs(CLASSES) do
        for _, npc in ipairs(UE.findAll(cls) or {}) do fn(npc, code) end
    end
end

function Npc.tickHost(now)
    if not UE.IsServer() or not Chan.isReady() then return end
    if cfg and cfg.SyncNpcs == false then return end
    if now - lastState < STATE_EVERY then return end
    lastState = now

    local entries, looks, alive = {}, 0, {}
    eachNpc(function(npc, code)
            if UE.alive(npc) and UE.TryGet(npc, "bHidden") ~= true then
                local id = idOf(npc)
                local okL, rawL = pcall(function() return npc:K2_GetActorLocation() end)
                local l = okL and UE.vec(rawL) or nil
                if id and l then
                    alive[id] = true
                    entries[#entries + 1] = table.concat({
                        id:match("(%d+)$") or id, code,
                        ("%.0f"):format(l.X), ("%.0f"):format(l.Y), ("%.0f"):format(l.Z),
                        num(UE.TryGet(npc, "Current Task")), num(UE.TryGet(npc, "Sub Task")),
                        num(UE.TryGet(npc, "Pick Up Level")), bool01(UE.TryGet(npc, "Has Basket")),
                        bool01(UE.TryGet(npc, "Is Holding something")),
                        num(UE.TryGet(npc, "Current Emotion")),
                    }, ",")

                    if looks < LOOKS_PER_TICK and (now - (lookSentAt[id] or -1e9)) > LOOK_EVERY then
                        local look = readLook(npc, id:match("(%d+)$") or id)
                        if look then
                            Chan.broadcast("npca", look)
                            lookSentAt[id] = now
                            looks = looks + 1
                        end
                    end
                end
            end
    end)
    for id in pairs(lookSentAt) do if not alive[id] then lookSentAt[id] = nil end end
    if #entries > 0 then Chan.broadcast("npcs", { d = table.concat(entries, ";") }) end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local hostNpcs = {}       -- hostId -> { code, x, y, z, task, sub, pick, basket, hold, emo }
local looks = {}          -- hostId -> look table (as sent)
local match = {}          -- hostId -> guest actor name
local taken = {}          -- guest actor name -> hostId
local styled = {}         -- guest actor name -> hostId whose look it wears
local missing = {}        -- path -> true when it would not load (paths only, never objects)
local reported = false

--[[
    Resolved EVERY time, never cached. 1.7.0's first version kept the loaded
    mesh / texture / material objects in a Lua table - and a Lua reference
    does not keep an Unreal object alive. Once the NPCs wearing an asset had
    despawned, garbage collection freed it, and the next NPC was handed the
    dangling pointer from the cache. An engine worker then read through it:
    seven guest crashes, one to two and a half minutes in, on the same
    instruction ("cmp byte ptr [rax+0x89]" reading through
    USkinnedMeshComponent::SkinnedAsset / UStaticMeshComponent::StaticMesh at
    +0x560 - both live there on this build, per the header dump). This is
    PROJECT.md 5's "never hold an actor pointer across frames", and it applies
    to assets just the same. Looking a loaded path up again is cheap
    (UE.findObject: 0.02 ms, where UE4SS's StaticFindObject measured 1-2 ms);
    only the paths that do not exist are remembered.
]]
local function asset(path)
    path = expand(path)
    if not path or missing[path] then return nil end
    local o = UE.findObject(path)
    if not UE.valid(o) and type(LoadAsset) == "function" then
        pcall(function() o = LoadAsset(path) end)
        if not UE.valid(o) then o = UE.findObject(path) end
    end
    if not UE.valid(o) then missing[path] = true return nil end
    return o
end

local function guestNpcs()
    local list = {}
    eachNpc(function(npc, code)
        if UE.alive(npc) then
            local id = idOf(npc)
            local ok, l = pcall(function() return UE.vec(npc:K2_GetActorLocation()) end)
            if id and ok and l then list[id] = { actor = npc, code = code, loc = l } end
        end
    end)
    return list
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.x, a.Y - b.y, a.Z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function applyLook(npc, look)
    local mesh = UE.TryGet(npc, "Mesh")
    if not UE.valid(mesh) then return false end
    -- SetSkinnedAssetAndUpdate(mesh, bReinitPose = true), NOT SetSkeletalMeshAsset.
    -- The Blueprint-facing SetSkeletalMeshAsset is SetSkeletalMesh(NewMesh,
    -- bReinitPose = false): it swaps the asset and keeps the pose buffers
    -- sized for the OLD one, which the parallel animation task then walks.
    -- 1.7.0's guests died on a Foreground Worker reading 0xffffffffffffffff a
    -- couple of minutes after the first NPC was restyled - three times, the
    -- same frames each time - and never with the body swap left out.
    local body = (cfg and cfg.NpcBodySwap == false) and nil or asset(look.m)
    if body then
        local cur = nil
        pcall(function() cur = mesh.SkeletalMesh end)
        if not (UE.valid(cur) and cur:GetFullName() == body:GetFullName()) then
            local ok = pcall(function() mesh:SetSkinnedAssetAndUpdate(body, true) end)
            if not ok then return false end     -- never fall back to the unsafe swap
        end
    end

    for key, comp in pairs({ h = "Hair", f = "Facial-Hair", a = "Facial-Accesory" }) do
        local c = UE.TryGet(npc, comp)
        if UE.valid(c) and look[key] ~= nil then
            local m = asset(look[key])
            pcall(function()
                if m then c:SetStaticMesh(m) end
                c:SetVisibility(m ~= nil, false)
            end)
        end
    end

    for i = 0, 4 do
        local spec = look["s" .. i]
        if type(spec) == "string" and spec ~= "" then
            local parentP, texP, tint = spec:match("^([^|]*)|([^|]*)|([^|]*)$")
            local parent = asset(parentP)
            if parent then
                -- Reuse the slot's dynamic material when it already has the
                -- right parent; create one only when it does not, and never
                -- by a fixed name. 1.7.0's first version passed "RT_Look_<i>"
                -- every time, and re-applying a look then created an object
                -- under a name that already existed - which Unreal satisfies
                -- by destroying the live one IN PLACE while the renderer and
                -- the animation workers still read it. The guest died on a
                -- Foreground Worker reading 0xffffffffffffffff (measured).
                local mid = nil
                pcall(function()
                    local cur = mesh:GetMaterial(i)
                    if UE.valid(cur) and UE.ClassNameOf(cur) == "MaterialInstanceDynamic"
                       and UE.valid(cur.Parent) and cur.Parent:GetFullName() == parent:GetFullName() then
                        mid = cur
                    end
                end)
                if not UE.valid(mid) then
                    pcall(function() mid = mesh:CreateDynamicMaterialInstance(i, parent, FName("None")) end)
                end
                if UE.valid(mid) then
                    local tex = asset(texP)
                    if tex then pcall(function() mid:SetTextureParameterValue(FName("Base Color"), tex) end) end
                    local r, g, b = (tint or ""):match("([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)")
                    if r then
                        pcall(function()
                            mid:SetVectorParameterValue(FName("Tint - Red Channel"),
                                { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = 1.0 })
                        end)
                    end
                end
            end
        end
    end

    -- Skin tone lives on the eye materials (slots 6 and 7).
    if type(look.e) == "string" and look.e ~= "" then
        for slot = 6, 7 do
            local mat = nil
            pcall(function() mat = mesh:GetMaterial(slot) end)
            if UE.valid(mat) then
                for key, r, g, b in look.e:gmatch("(%a)=([%d%.%-]+),([%d%.%-]+),([%d%.%-]+);") do
                    local name = key == "s" and "Skin Tone" or "SSS Skin Tone"
                    pcall(function()
                        mat:SetVectorParameterValue(FName(name),
                            { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = 1.0 })
                    end)
                end
            end
        end
    end
    return true
end

local function onState(fields)
    if UE.IsServer() or type(fields.d) ~= "string" then return end
    local seen = {}
    for entry in fields.d:gmatch("[^;]+") do
        local id, code, x, y, z, task, sub, pick, basket, hold, emo =
            entry:match("^([^,]+),(%a),(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%d+),(%d+),([01]),([01]),(%d+)$")
        if id then
            seen[id] = true
            hostNpcs[id] = { code = code, x = tonumber(x), y = tonumber(y), z = tonumber(z),
                             task = tonumber(task), sub = tonumber(sub), pick = tonumber(pick),
                             basket = basket == "1", hold = hold == "1", emo = tonumber(emo) }
        end
    end
    for id in pairs(hostNpcs) do
        if not seen[id] then
            hostNpcs[id] = nil
            if match[id] then taken[match[id]] = nil end
            match[id] = nil
        end
    end

    local mine = guestNpcs()
    -- Drop pairings whose guest NPC is gone or has drifted away.
    for hid, gname in pairs(match) do
        local g, h = mine[gname], hostNpcs[hid]
        if not g or not h or dist(g.loc, h) > LOSE_RADIUS then
            match[hid] = nil
            taken[gname] = nil
        end
    end
    -- Pair the rest, nearest first.
    for hid, h in pairs(hostNpcs) do
        if not match[hid] then
            local best, bestD = nil, MATCH_RADIUS
            for gname, g in pairs(mine) do
                if not taken[gname] and g.code == h.code then
                    local d = dist(g.loc, h)
                    if d < bestD then best, bestD = gname, d end
                end
            end
            if best then match[hid] = best taken[best] = hid end
        end
    end

    -- Apply: animation inputs every time, the look once per pairing.
    local restyled = 0
    for hid, gname in pairs(match) do
        local g, h = mine[gname], hostNpcs[hid]
        local npc = g and g.actor
        if npc and h then
            UE.TrySet(npc, "Current Task", h.task)
            UE.TrySet(npc, "Sub Task", h.sub)
            UE.TrySet(npc, "Pick Up Level", h.pick)
            UE.TrySet(npc, "Has Basket", h.basket)
            UE.TrySet(npc, "Is Holding something", h.hold)
            UE.TrySet(npc, "Current Emotion", h.emo)
            if looks[hid] and styled[gname] ~= hid and not (cfg and cfg.SyncNpcLooks == false) then
                local ran, ok = Safety.guard(RESTYLE_OP, function() return applyLook(npc, looks[hid]) end)
                if not ran then return end
                styled[gname] = hid
                if ok then restyled = restyled + 1 end
            end
        end
    end
    if restyled > 0 and not reported then
        reported = true
        Log.info("NPCs: wearing the host's looks and animating from the host's state " ..
                 "(%d restyled so far)", restyled)
    end
end

local function lookKey(f)
    local parts = {}
    for _, k in ipairs({ "m", "h", "f", "a", "s0", "s1", "s2", "s3", "s4", "e" }) do
        parts[#parts + 1] = tostring(f[k])
    end
    return table.concat(parts, "|")
end

local function onLook(fields)
    if UE.IsServer() or type(fields.i) ~= "string" then return end
    -- The host re-sends every look every few seconds for guests who join
    -- late. Only a look that actually CHANGED is applied again.
    local old = looks[fields.i]
    if old and lookKey(old) == lookKey(fields) then return end
    looks[fields.i] = fields
    local gname = match[fields.i]
    if gname then styled[gname] = nil end
end

function Npc.reset()
    hostNpcs, looks, match, taken, styled = {}, {}, {}, {}, {}
    missing = {}
    lookSentAt, lastState, reported = {}, 0, false
end

function Npc.stats()
    local h, m, l = 0, 0, 0
    for _ in pairs(hostNpcs) do h = h + 1 end
    for _ in pairs(match) do m = m + 1 end
    for _ in pairs(looks) do l = l + 1 end
    return { host = h, matched = m, looks = l }
end

function Npc.init(config)
    cfg = config
    Chan.on("npcs", function(f) Log.guard("npc state", onState, f) end)
    Chan.on("npca", function(f) Log.guard("npc look", onLook, f) end)
end

return Npc
