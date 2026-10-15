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
                              + whether its thought bubble is up, and its icon
      look  (once, refreshed) body mesh, hair / facial meshes and their
                              materials, and for each body slot the material,
                              base-colour texture and tint - read straight off
                              its dynamic materials (8 slots: skin, top,
                              bottom, shoes, hair, mouth, left eye, right eye;
                              measured) - plus its size, walk rate, eyelids
                              and, for staff, the name on the badge
    and the guest rebuilds it with the engine's own calls
    (SetSkinnedAssetAndUpdate, CreateDynamicMaterialInstance, Set*ParameterValue)
    - each one tried by hand on a guest NPC first, all accepted.

    WHY A GUEST'S NPC NEEDS MORE THAN ITS CLOTHES (1.7.0, reported: "npcs have
    no walking animations or face features or hair", "all of the npcs have
    some speech bubble"). AI_Base_Character's BeginPlay runs Bind Init, which
    casts GetGameMode to Core_Gamemode_C - and a guest has no GameMode. The
    cast fails, Bind Init waits a second and tries again, forever, and the
    second half of the NPC's creation ("Step 2 of creation Skin") never runs
    on a guest. Measured on the store's employee, host against guest:

      Character Scale        0.996 / 0      the walk animation's play rate is
                                            Max Speed Walk Scale / Character
                                            Scale, and Unreal's divide by zero
                                            answers 0: rate 0.80 / 0.0, the walk
                                            cycle frozen while the capsule glides
      Hair, Facial-Hair      on the head socket / on the capsule's centre,
                                            inside the body: bald
      mouth, eyes            dynamic materials with the mouth's sprite frame
                                            and the eyelids / the plain
                                            defaults: a grimace, staring
      Widget3D_QuestRequest  hidden / shown, with the default slush icon on
                                            every NPC in town
      name badge             "Adam" / "Text Name"
      actor tick             on / off

    Each of those is put right below from the host's numbers. The actor tick
    is deliberately NOT switched on: its first job (Limit Walk Speed by
    rotation) eases the actor toward GetControlRotation, which with no AI
    controller - a guest has none - is zero, and it would drag every NPC on a
    guest's screen round to face east between network updates. What else that
    tick does that a guest can see - turning the thought bubble to the player
    - is done here.

    A GUEST'S OWN NPCs. The level's AI Director exists on a guest too, and the
    ActorGatherer starts its spawn timer (Init Director) on every machine. On
    a guest it spawned walk-bys of its own - measured: 12 within a few minutes,
    Role Authority on the guest, no controller (a client never spawns one), so
    they stood frozen at the spawn points, bald, each with a bubble, never
    seen by the host. The timer does nothing but spawn ("Event - Timer" ->
    "Tick - Clients"), so a guest stops it, and removes any NPC its own game
    made: everything real reaches a guest by replication, as a simulated proxy.

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
local Replication = require("replication")

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
local STRAYS_OP    = "removing the NPCs a guest's own game spawns"
local MAX_SLOTS    = 8        -- body material slots (measured: 8 on every body)
local HEAD_SLOTS   = 3        -- on a hair / beard / glasses mesh; a hat has 2
local SWEEP_EVERY  = 2.0      -- guest: the AI Director and stray-NPC check
local HEAD = { h = "Hair", f = "Facial-Hair", a = "Facial-Accesory" }

-- The face, as AI_Base_Character's AI Emotion sets it (read from its
-- bytecode): per emotion 0-9, a frame of the mouth's sprite sheet and the
-- weights of the two face morph targets. Its blend to them is a timeline;
-- a guest sets them outright.
local MOUTH_FRAME = { [0] = 0.24, 0.24, 0.12, 0.0, 0.48, 0.36, 0.84, 0.96, 0.72, 0.6 }
local SURPRISED   = { [0] = 0.0, 0.0, 0.0, 0.0, 1.0, 0.5, -0.1, -0.2, 0.0, 0.0 }
local ANGRY       = { [0] = 0.0, 0.0, -0.1, -0.2, 0.0, 0.0, -0.3, 0.3, 1.0, 0.0 }
-- Where the face slots are when a body will not say (measured, SK_CHA_M_01).
local FACE_SLOT = { Mouth = 5, EyeL = 6, EyeR = 7 }

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

local function isDynamic(mat)
    return UE.valid(mat) and UE.ClassNameOf(mat) == "MaterialInstanceDynamic"
end

--- A body's material slot by name ("Mouth", "EyeL", "EyeR"), or where it
--- was measured when the body cannot say.
local function slotIndex(mesh, name)
    local i = nil
    pcall(function() i = mesh:GetMaterialIndex(FName(name)) end)
    if type(i) == "number" and i >= 0 then return i end
    return FACE_SLOT[name]
end

--------------------------------------------------------------------------
-- Host: read a look off a live NPC
--------------------------------------------------------------------------

--- "parent|base colour texture|tint" of one material slot on a skeletal or
--- static mesh. A dynamic material is rebuilt from its parent; anything else
--- IS what the guest should wear (its own parent would lose its settings).
local function readSlot(target, i)
    local mat = nil
    pcall(function() mat = target:GetMaterial(i) end)
    if not UE.valid(mat) then return "" end
    local parent, tex, tint = "", "", ""
    if isDynamic(mat) then pcall(function() parent = pathOf(mat.Parent) end) end
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
        local mat = mesh:GetMaterial(slotIndex(mesh, "EyeL"))
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

local function f3(v) return type(v) == "number" and ("%.3f"):format(v) or nil end

local function readLook(npc, id, code)
    local look = { i = id }
    local mesh = UE.TryGet(npc, "Mesh")
    if not UE.valid(mesh) then return nil end
    pcall(function() look.m = pathOf(mesh.SkeletalMesh) end)
    for key, compName in pairs(HEAD) do
        -- A piece the host's NPC rolled without is DESTROYED there (Set Hair
        -- Mesh Style: K2_DestroyComponent), not hidden, while the guest's copy
        -- still has the class default on it - so "" (hide it) whenever the
        -- host has nothing to show.
        local c = UE.TryGet(npc, compName)
        local vis = false
        if UE.valid(c) then pcall(function() vis = c:IsVisible() end) end
        look[key] = vis and pathOf(UE.TryGet(c, "StaticMesh")) or ""
        if look[key] ~= "" then
            -- The hair colour is a dynamic material on these too, not just on
            -- the body's hair slot (measured: Hair m0 = MID of MI_CHA_Hair_Brown).
            local specs = {}
            for i = 0, HEAD_SLOTS - 1 do
                local s = readSlot(c, i)
                if s == "" then break end
                specs[#specs + 1] = s
            end
            look[key .. "m"] = table.concat(specs, "^")
        end
    end
    local slots = MAX_SLOTS
    pcall(function() slots = math.min(MAX_SLOTS, mesh:GetNumMaterials()) end)
    for i = 0, slots - 1 do look["s" .. i] = readSlot(mesh, i) end
    look.e = readEyes(mesh)

    -- What a guest's copy never works out for itself (see the top).
    look.cs = f3(UE.TryGet(npc, "Character Scale"))
    look.ws = f3(UE.TryGet(npc, "Max Speed Walk Scale"))
    local anchor = UE.TryGet(npc, "Bubble_Anchor")
    if UE.valid(anchor) then
        local rel = UE.vec(UE.TryGet(anchor, "RelativeLocation"))
        if rel then look.bz = ("%.1f"):format(rel.Z) end
    end
    local lid = UE.vec(UE.TryGet(npc, "Eyelid Base Height"))
    if lid then look.eb = ("%.3f,%.3f"):format(lid.X, lid.Y) end
    if code == "E" then
        local name = nil
        pcall(function() name = npc["Client Name"]:ToString() end)
        if type(name) == "string" and name ~= "" then look.nm = name end
    end
    return look
end

--- Whether the NPC's thought bubble is up ("1") and the icon in it.
local function readBubble(npc)
    local comp = UE.TryGet(npc, "Widget3D_QuestRequest")
    if not UE.valid(comp) then return "0", "" end
    local shown = false
    pcall(function() shown = comp:IsVisible() end)
    if not shown then return "0", "" end
    local icon = ""
    pcall(function() icon = pathOf(comp:GetWidget().Front.Brush.ResourceObject) end)
    return "1", icon
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

--[[
    WHAT AN NPC SAYS (bp/AI_Base_Character.txt "AI Talk about a problem"
    @38429, "AI Toggle a permanent problem" @44932). The line of text over an
    NPC's head - a customer who cannot find a film, staff with a problem at
    the till - is Widget3D_AiSpeakInWorld, a screen-space widget on every
    NPC, filled by those two functions. Everything that calls them is AI or
    store logic, so it runs on the host only and a guest's NPCs never said a
    word. The host hooks both (a hook on a Blueprint function runs after it),
    queues what was said, and sends it from the tick; the guest hands it to
    the same widget on its copy of that NPC. A permanent line (the till's
    "waiting" message) is said again every few seconds while it is up, for a
    guest who joins late.
]]
local SPEAK_FN = "/Game/VideoStore/core/ai/pawn/AI_Base_Character.AI_Base_Character_C:AI Talk about a problem"
local PERMANENT_FN = "/Game/VideoStore/core/ai/pawn/AI_Base_Character.AI_Base_Character_C:AI Toggle a permanent problem"
local SPEECH_RESEND = 5.0
local said = {}               -- host: queued lines { i, k, m, t, v, s }
local permanent = {}          -- host: npc id -> the permanent line it shows
local speechHooks = {}        -- host: function path -> the address it was hooked at
local nextSpeechHook, lastPermanent = 0, 0

local function paramValue(p)
    local v = p
    pcall(function() v = p:get() end)
    return v
end

local function stringOf(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or nil
end

local function speakerId(ctx)
    local npc = paramValue(ctx)
    if not UE.valid(npc) then return nil end
    local id = idOf(npc)
    return id and (id:match("(%d+)$") or id) or nil
end

local function onSpeak(ctx, msgP, timeP, soundP)
    -- Nobody to tell: nothing queued (the tick does not send while no guest
    -- is connected, and the queue would come out in one burst on a join).
    if not UE.IsServer() or not Chan.isReady() or #said >= 32 then return end
    local id, msg = speakerId(ctx), stringOf(paramValue(msgP))
    if not (id and msg and msg ~= "") then return end
    local t = tonumber(paramValue(timeP)) or 2
    local sound = paramValue(soundP)
    said[#said + 1] = { i = id, k = "t", m = msg, t = ("%.2f"):format(t),
                        s = UE.valid(sound) and (UE.pathOf(sound) or "") or "" }
end

local function onPermanent(ctx, msgP, visibleP)
    if not UE.IsServer() then return end
    local id = speakerId(ctx)
    if not id then return end
    local visible = paramValue(visibleP) == true
    local msg = visible and (stringOf(paramValue(msgP)) or "") or ""
    -- Kept whatever happens below: it is what a guest joining later is told.
    permanent[id] = visible and msg or nil
    if not Chan.isReady() or #said >= 32 then return end
    said[#said + 1] = { i = id, k = "p", m = msg, v = visible and "1" or "0" }
end

--- Hook both, and again when the class has been loaded anew (a new world):
--- a hook belongs to the function object it was put on.
local function hookSpeech(now)
    if now < nextSpeechHook then return end
    nextSpeechHook = now + 5
    for path, fn in pairs({ [SPEAK_FN] = onSpeak, [PERMANENT_FN] = onPermanent }) do
        local f = StaticFindObject(path)
        if UE.valid(f) then
            local addr = nil
            pcall(function() addr = f:GetAddress() end)
            if addr and speechHooks[path] ~= addr then
                local ok = pcall(function()
                    RegisterHook(path, function(...)
                        local args = { ... }
                        Log.guard("npc speech hook", function() fn(table.unpack(args)) end)
                    end)
                end)
                if ok then
                    speechHooks[path] = addr
                    Log.debug("NPCs: what they say goes to the guests (%s)", path:match(":(.+)$"))
                end
            end
        end
    end
end

local function flushSpeech(now)
    hookSpeech(now)
    if now - lastPermanent > SPEECH_RESEND then
        lastPermanent = now
        for id, msg in pairs(permanent) do
            said[#said + 1] = { i = id, k = "p", m = msg, v = "1" }
        end
    end
    if #said == 0 then return end
    local lines = said
    said = {}
    for _, line in ipairs(lines) do Chan.broadcast("npct", line) end
end

function Npc.tickHost(now)
    if not UE.IsServer() or not Chan.isReady() then return end
    if cfg and cfg.SyncNpcs == false then return end
    flushSpeech(now)
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
                    -- The cash a customer holds out at the till: the pay task
                    -- (BTTask_Checkout-Pay, Setup Pay With Money @252) spawns
                    -- a Money_NPC-Stash_C into the hand on the host only, and
                    -- its class does not replicate. REPORTED: on a guest the
                    -- customer held out an empty hand (the basket, see below).
                    local stash = UE.TryGet(npc, "Money Stash")
                    if UE.alive(stash) then Replication.patchActor(stash) end
                    local bubble, icon = readBubble(npc)
                    entries[#entries + 1] = table.concat({
                        id:match("(%d+)$") or id, code,
                        ("%.0f"):format(l.X), ("%.0f"):format(l.Y), ("%.0f"):format(l.Z),
                        num(UE.TryGet(npc, "Current Task")), num(UE.TryGet(npc, "Sub Task")),
                        num(UE.TryGet(npc, "Pick Up Level")), bool01(UE.TryGet(npc, "Has Basket")),
                        bool01(UE.TryGet(npc, "Is Holding something")),
                        num(UE.TryGet(npc, "Current Emotion")),
                        bubble, icon,
                    }, ",")

                    if looks < LOOKS_PER_TICK and (now - (lookSentAt[id] or -1e9)) > LOOK_EVERY then
                        local look = readLook(npc, id:match("(%d+)$") or id, code)
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
    for id in pairs(permanent) do
        local here = false
        for full in pairs(alive) do
            if (full:match("(%d+)$") or full) == id then here = true break end
        end
        if not here then permanent[id] = nil end
    end
    if #entries > 0 then Chan.broadcast("npcs", { d = table.concat(entries, ";") }) end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local hostNpcs = {}       -- hostId -> { code, x, y, z, task, sub, pick, basket, hold, emo, bubble, icon }
local looks = {}          -- hostId -> look table (as sent)
local match = {}          -- hostId -> guest actor name
local taken = {}          -- guest actor name -> hostId
local styled = {}         -- guest actor name -> hostId whose look it wears
local faceOf = {}         -- guest actor name -> emotion its face shows
local bubbleOf = {}       -- guest actor name -> bubble state it shows ("0", or "1" .. icon)
local bubbleUp = {}       -- guest actor name -> true while its bubble is up
local basketOf = {}       -- guest actor name -> whether its basket is shown
local missing = {}        -- path -> true when it would not load (paths only, never objects)
local reported = false
local lastSweep = -1e9
local strayReport = { director = false, removed = 0 }

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

--- A guest's own NPCs - spawned by its own game, owned by it (Role
--- Authority) - against the ones that came from the host (simulated proxies).
local function strayed(npc)
    return UE.TryGet(npc, "Role") == UE.ROLE_AUTHORITY
end

local function guestNpcs()
    local list = {}
    eachNpc(function(npc, code)
        if UE.alive(npc) and not strayed(npc) then
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

--- Dress one material slot of a skeletal or static mesh from a readSlot spec.
local function dressSlot(target, i, spec)
    local parentP, texP, tint = spec:match("^([^|]*)|([^|]*)|([^|]*)$")
    local parent = asset(parentP)
    if not parent then return end
    -- Reuse the slot's dynamic material when it already has the right parent;
    -- create one only when it does not, and never by a fixed name. 1.7.0's
    -- first version passed "RT_Look_<i>" every time, and re-applying a look
    -- then created an object under a name that already existed - which Unreal
    -- satisfies by destroying the live one IN PLACE while the renderer and
    -- the animation workers still read it. The guest died on a Foreground
    -- Worker reading 0xffffffffffffffff (measured).
    local mid = nil
    pcall(function()
        local cur = target:GetMaterial(i)
        if isDynamic(cur) and UE.valid(cur.Parent) and cur.Parent:GetFullName() == parent:GetFullName() then
            mid = cur
        end
    end)
    if not UE.valid(mid) then
        pcall(function() mid = target:CreateDynamicMaterialInstance(i, parent, FName("None")) end)
    end
    if not UE.valid(mid) then return end
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

--- Size and walk rate, which drive the walk animation's play rate (see the top).
local function applySize(npc, mesh, look)
    local cs, ws, bz = tonumber(look.cs), tonumber(look.ws), tonumber(look.bz)
    if cs and cs > 0.2 and cs < 3.0 then
        UE.TrySet(npc, "Character Scale", cs)
        pcall(function() mesh:SetWorldScale3D({ X = cs, Y = cs, Z = cs }) end)
    end
    if ws and ws >= 0.0 and ws < 5.0 then UE.TrySet(npc, "Max Speed Walk Scale", ws) end
    -- Adjust Scale moves the bubble with the head; the host's number, so a
    -- second apply cannot move it twice.
    local anchor = UE.TryGet(npc, "Bubble_Anchor")
    local rel = (bz and UE.valid(anchor)) and UE.vec(UE.TryGet(anchor, "RelativeLocation")) or nil
    if rel and math.abs(rel.Z - bz) > 0.05 then
        pcall(UE.withHit, function(hit)
            anchor:K2_SetRelativeLocation({ X = rel.X, Y = rel.Y, Z = bz }, false, hit, false)
        end)
    end
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

    applySize(npc, mesh, look)

    for key, comp in pairs(HEAD) do
        local c = UE.TryGet(npc, comp)
        if UE.valid(c) and look[key] ~= nil then
            local m = asset(look[key])
            pcall(function()
                if m then c:SetStaticMesh(m) end
                c:SetVisibility(m ~= nil, false)
            end)
            if m then
                local i = 0
                for spec in (look[key .. "m"] or ""):gmatch("[^%^]+") do
                    dressSlot(c, i, spec)
                    i = i + 1
                end
            end
        end
    end
    -- Onto the head. The guest's copy never ran its own Attach Child to
    -- Skeletal (it is part of the start-up that waits for a GameMode), so the
    -- hair sat at the capsule's centre, inside the body (measured). It is the
    -- NPC's own event: three K2_AttachToComponent calls to HeadTop_EndSocket.
    pcall(function() npc["Attach Child to Skeletal"](npc) end)

    for i = 0, MAX_SLOTS - 1 do
        local spec = look["s" .. i]
        if type(spec) == "string" and spec ~= "" then dressSlot(mesh, i, spec) end
    end

    -- Skin tone and eyelids live on the eye materials. The host's eyelid blinks
    -- from its tick; a guest's NPC keeps it open at this NPC's own height.
    local lidX, lidY = (look.eb or ""):match("^([%d%.%-]+),([%d%.%-]+)$")
    for _, eye in ipairs({ "EyeL", "EyeR" }) do
        local mat = nil
        pcall(function() mat = mesh:GetMaterial(slotIndex(mesh, eye)) end)
        if UE.valid(mat) then
            for key, r, g, b in (look.e or ""):gmatch("(%a)=([%d%.%-]+),([%d%.%-]+),([%d%.%-]+);") do
                local name = key == "s" and "Skin Tone" or "SSS Skin Tone"
                pcall(function()
                    mat:SetVectorParameterValue(FName(name),
                        { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = 1.0 })
                end)
            end
            if lidX then
                pcall(function()
                    mat:SetVectorParameterValue(FName("Eyelid"),
                        { R = tonumber(lidX), G = tonumber(lidY), B = 0.0, A = 1.0 })
                end)
            end
        end
    end

    -- A member of staff's name badge (Staff_NameSticker, a child actor).
    if type(look.nm) == "string" and look.nm ~= "" then
        local sticker = UE.TryGet(npc, "Staff_NameSticker")
        local badge = UE.valid(sticker) and UE.TryGet(sticker, "ChildActor") or nil
        local name = look.nm:gsub("%c", ""):sub(1, 40)
        if UE.valid(badge) and name ~= "" then
            pcall(function() badge["Update Staff Name"](badge, FName(name)) end)
        end
    end
    return true
end

--- The mouth and the two face morph targets for an emotion.
local function applyFace(npc, emo)
    local mesh = UE.TryGet(npc, "Mesh")
    if not UE.valid(mesh) or MOUTH_FRAME[emo] == nil then return end
    local mouth = nil
    pcall(function() mouth = mesh:GetMaterial(slotIndex(mesh, "Mouth")) end)
    if isDynamic(mouth) then
        pcall(function() mouth:SetScalarParameterValue(FName("Frame"), MOUTH_FRAME[emo]) end)
    end
    pcall(function()
        mesh:SetMorphTarget(FName("Surprised"), SURPRISED[emo], true)
        mesh:SetMorphTarget(FName("Angry"), ANGRY[emo], true)
    end)
end

--- The thought bubble: shown with the host's icon, or hidden.
local function applyBubble(npc, shown, icon)
    local comp = UE.TryGet(npc, "Widget3D_QuestRequest")
    if not UE.valid(comp) then return end
    pcall(function() comp:SetVisibility(shown, false) end)
    local tex = shown and asset(icon) or nil
    if tex then
        -- UI_Quest-Bubble's own Load Image ends in exactly this call.
        pcall(function() comp:GetWidget().Front:SetBrushFromTexture(tex, false) end)
    end
end

local function onState(fields)
    if UE.IsServer() or type(fields.d) ~= "string" then return end
    local seen = {}
    for entry in fields.d:gmatch("[^;]+") do
        local id, code, x, y, z, task, sub, pick, basket, hold, emo, bubble, icon =
            entry:match("^([^,]+),(%a),(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%d+),(%d+),([01]),([01]),(%d+),([01]),([^,]*)$")
        if id then
            seen[id] = true
            hostNpcs[id] = { code = code, x = tonumber(x), y = tonumber(y), z = tonumber(z),
                             task = tonumber(task), sub = tonumber(sub), pick = tonumber(pick),
                             basket = basket == "1", hold = hold == "1", emo = tonumber(emo),
                             bubble = bubble, icon = icon }
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
    for gname in pairs(bubbleUp) do
        if not taken[gname] then bubbleUp[gname] = nil end
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
            if best then
                match[hid] = best
                taken[best] = hid
                faceOf[best], bubbleOf[best], basketOf[best] = nil, nil, nil
            end
        end
    end

    -- Apply: animation inputs and the bubble every time, the look once per
    -- pairing, the face whenever the emotion changes.
    local restyled = 0
    for hid, gname in pairs(match) do
        local g, h = mine[gname], hostNpcs[hid]
        local npc = g and g.actor
        if npc and h then
            UE.TrySet(npc, "Current Task", h.task)
            UE.TrySet(npc, "Sub Task", h.sub)
            UE.TrySet(npc, "Pick Up Level", h.pick)
            -- The basket: Has Basket is what the animation reads, but the
            -- basket's mesh is shown and hidden by Toggle Visiblity Basket,
            -- which sets both (AI_Client_Character @292). REPORTED: a guest
            -- saw customers hand over their basket at the till - the host had
            -- hidden it when the tapes came out, the guest's stayed up.
            if basketOf[gname] ~= h.basket and UE.TryCall(npc, "Toggle Visiblity Basket", h.basket) then
                basketOf[gname] = h.basket
            end
            UE.TrySet(npc, "Has Basket", h.basket)
            UE.TrySet(npc, "Is Holding something", h.hold)
            UE.TrySet(npc, "Current Emotion", h.emo)
            local bubble = h.bubble == "1" and ("1" .. h.icon) or "0"
            if bubbleOf[gname] ~= bubble then
                applyBubble(npc, h.bubble == "1", h.icon)
                bubbleOf[gname] = bubble
                bubbleUp[gname] = h.bubble == "1" or nil
            end
            if looks[hid] and styled[gname] ~= hid and not (cfg and cfg.SyncNpcLooks == false) then
                local ran, ok = Safety.guard(RESTYLE_OP, function() return applyLook(npc, looks[hid]) end)
                if not ran then return end
                styled[gname] = hid
                faceOf[gname] = nil
                if ok then restyled = restyled + 1 end
            end
            if styled[gname] == hid and faceOf[gname] ~= h.emo then
                applyFace(npc, h.emo)
                faceOf[gname] = h.emo
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
    for _, k in ipairs({ "m", "h", "f", "a", "hm", "fm", "am", "s0", "s1", "s2", "s3", "s4",
                         "s5", "s6", "s7", "e", "cs", "ws", "bz", "eb", "nm" }) do
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

local shownPermanent = {}     -- guest actor name -> the permanent line it shows
local saidCount = 0           -- guest: lines put over an NPC's head

--- A line one of the host's NPCs said, on this machine's copy of it: the
--- speech widget's own functions (what the NPC's events call). With a sound,
--- the NPC's own event instead, which plays it at the mouth too.
local function onSpeech(fields)
    if UE.IsServer() or type(fields.i) ~= "string" then return end
    local gname = match[fields.i]
    local g = gname and guestNpcs()[gname] or nil
    local npc = g and g.actor
    if not UE.alive(npc) then return end
    local comp = UE.TryGet(npc, "Widget3D_AiSpeakInWorld")
    local w = nil
    if UE.valid(comp) then pcall(function() w = comp:GetWidget() end) end
    if not UE.valid(w) then return end
    local msg = type(fields.m) == "string" and fields.m or ""
    if fields.k == "t" and msg ~= "" then
        local t = tonumber(fields.t) or 2
        local sound = (fields.s and fields.s ~= "") and UE.load(fields.s) or nil
        if UE.valid(sound) then
            UE.TryCall(npc, "AI Talk about a problem", msg, t, sound)
        else
            UE.TryCall(w, "Set Text and Show Message", msg, t)
        end
        saidCount = saidCount + 1
    elseif fields.k == "p" then
        if fields.v == "1" and msg ~= "" then
            if shownPermanent[gname] ~= msg then
                UE.TryCall(w, "Set Text And Show Message Permanent", msg)
                shownPermanent[gname] = msg
                saidCount = saidCount + 1
            end
        elseif shownPermanent[gname] then
            UE.TryCall(w, "Start Animation Hidden Message")
            shownPermanent[gname] = nil
        end
    end
end

--- A guest: stop its own AI Director spawning, and remove what it spawned.
local function sweepStrays(now)
    if now - lastSweep < SWEEP_EVERY then return end
    lastSweep = now
    local ksl, director = UE.GetKismetSystemLibrary(), UE.findFirst("AI_Director_C")
    if ksl and UE.valid(director) then
        local running = false
        pcall(function() running = ksl:K2_IsTimerActive(director, "Event - Timer") end)
        if running then
            pcall(function() ksl:K2_ClearTimer(director, "Event - Timer") end)
            if not strayReport.director then
                strayReport.director = true
                Log.info("NPCs: stopped this game's own AI Director - the host's spawns the town")
            end
        end
    end
    local strays = {}
    eachNpc(function(npc)
        if UE.alive(npc) and strayed(npc) then strays[#strays + 1] = npc end
    end)
    if #strays == 0 then return end
    local ran = Safety.guard(STRAYS_OP, function()
        for _, npc in ipairs(strays) do npc:K2_DestroyActor() end
    end)
    if ran then
        if strayReport.removed == 0 then
            Log.info("NPCs: removed %d this game had spawned for itself (frozen at the spawn points, " ..
                     "never seen by the host)", #strays)
        end
        strayReport.removed = strayReport.removed + #strays
    end
end

--- Guest, every tick: the strays, and each bubble that is up turned toward
--- this player - the host's NPC does that in its own tick (Set Bubble
--- Rotation to LookAt Player), which a guest's copy does not run.
function Npc.tickGuest(now)
    if UE.IsServer() or (cfg and cfg.SyncNpcs == false) then return end
    sweepStrays(now)
    if next(bubbleUp) == nil then return end
    local pawn = UE.GetPawn()
    local okP, me = pcall(function() return UE.vec(pawn:K2_GetActorLocation()) end)
    if not (okP and me) then return end
    eachNpc(function(npc)
        local id = idOf(npc)
        if id and bubbleUp[id] then
            local anchor = UE.TryGet(npc, "Bubble_Anchor")
            local ok, l = pcall(function() return UE.vec(npc:K2_GetActorLocation()) end)
            if UE.valid(anchor) and ok and l then
                local yaw = math.deg(math.atan(me.Y - l.Y, me.X - l.X))
                pcall(UE.withHit, function(hit)
                    anchor:K2_SetWorldRotation(UE.rotArg({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }), false, hit, false)
                end)
            end
        end
    end)
end

function Npc.reset()
    hostNpcs, looks, match, taken, styled = {}, {}, {}, {}, {}
    faceOf, bubbleOf, bubbleUp, basketOf = {}, {}, {}, {}
    said, permanent, shownPermanent = {}, {}, {}
    nextSpeechHook, lastPermanent = 0, 0
    missing = {}
    lookSentAt, lastState, reported = {}, 0, false
    lastSweep, strayReport = -1e9, { director = false, removed = 0 }
end

function Npc.stats()
    local h, m, l = 0, 0, 0
    for _ in pairs(hostNpcs) do h = h + 1 end
    for _ in pairs(match) do m = m + 1 end
    for _ in pairs(looks) do l = l + 1 end
    return { host = h, matched = m, looks = l, strays = strayReport.removed, said = saidCount }
end

function Npc.init(config)
    cfg = config
    Chan.on("npcs", function(f) Log.guard("npc state", onState, f) end)
    Chan.on("npca", function(f) Log.guard("npc look", onLook, f) end)
    Chan.on("npct", function(f) Log.guard("npc speech", onSpeech, f) end)
end

return Npc
