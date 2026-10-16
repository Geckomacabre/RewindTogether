--[[
    Rewind Together - wallpaper, floors, ceilings and furniture skins on a guest

    WHAT A GUEST SAW (measured, 1.7.x)

    The level's default store: wood-panel walls, a black ceiling, a grey
    carpet and a blue counter - while the host had blue walls, a starry
    ceiling and carpet and a yellow counter. Every one of those is a Wall_C
    (walls, Floor_C, Ceilling_C and Desk_C all derive from it), and its look
    is two numbers on its AC_MeshSkin_C component, "Current Mesh Use" and
    "Current Skin Use". Those two ARE replicated - two of the game's three
    replicated Blueprint variables - and 99 of 102 walls had the host's
    numbers on the guest. Three things kept them off the screen:

      * Nothing on a guest turns the numbers into a mesh and materials. A wall
        is dressed only while the save loads: the GameMode's load pipeline
        calls Wall.Load, which calls Set new Mesh -> AC_MeshSkin Load Asset ->
        the wall's Asset Loaded handler -> Set new skin -> Load Material
        (bp/Wall.txt @2442, @1582). A guest never loads a save, and
        AC_MeshSkin's own BeginPlay does nothing (bp/AC_MeshSkin.txt @3733).
        Shelves do dress themselves at BeginPlay (Manual Load Asset), but
        there is no RepNotify, so a skin changed later never shows anywhere
        but on the host.
      * Three walls had the wrong numbers: Unreal sends a value only where it
        differs from the class default, and on those walls the host's value
        was the default while the level the guest loaded holds another.
      * One display shelf read skin 6 on the host and 0 on the guest.

    WHAT THIS DOES

    The host lists every AC_MeshSkin owner (eight base classes, through
    GetAllActorsOfClass) every few seconds and sends what changed - class,
    position, mesh, skin - plus everything when a guest arrives and every
    30 s. The guest finds the same object by class and position (the names
    of anything spawned at runtime differ between the machines), writes the
    two numbers and loads them the way the game does:

      * a wall: "Savegame data loaded" = false, then Load Asset(false). The
        wall's own Asset Loaded handler sets the mesh and applies the skin,
        exactly as on a save load. NOT Load Asset(true): its "force material"
        path sets the skin to 0 first (bp/AC_MeshSkin.txt @3246) - which is
        what the first attempt here measured.
      * anything else: Manual Load Asset when the mesh changed (the game's own
        first-load path: mesh now, materials a second later), Load Material
        when only the skin did.

    MEASURED: with the host's numbers written and applied this way, the
    guest's store matched the host's - starry ceiling and carpet, blue walls,
    yellow counter.

    The shelf titles (the genre cards over the shelves) and the text signs
    ride the same machinery with their own messages - see "Shelf titles and
    text signs" below.
]]

local Log  = require("log")
local UE   = require("ue")
local Chan = require("rpcchan")

local SkinSync = {}

-- Every AC_MeshSkin owner in a store derives from one of these (header dump):
-- Wall_C covers the walls, Floor_C, Ceilling_C and Desk_C; Shelve_C the
-- shelves, displays, storage and the clearance bin; Decoration_C the signs
-- and ornaments. StoreName_C has one too, and worldsync.lua owns the sign.
local OWNERS = { "Wall_C", "Shelve_C", "Decoration_C", "PosterFrame_C",
                 "ShelveTitle_C", "SnackShelf_C", "Arcade_C", "CandyDispenser_Base_C" }

local POLL_EVERY    = 2.0     -- host: look for changes
local FULL_EVERY    = 30.0    -- host: send everything anyway
local CHUNK         = 60      -- entries per message (~2.5 KB)
local MATCH_DIST    = 8.0     -- cm: the same object on both machines
local RESOLVE_EVERY = 1.0     -- guest: retry what was not found yet
local GIVE_UP_AFTER = 40.0    -- guest: forget it; the next full list resends it
-- Packed furniture waits at Z -2000 (MovableActor) and -5000; several of the
-- same class can sit at the same spot, and nobody can see them anyway.
local HIDDEN_BELOW  = -1000

--[[
    CHANGES, NOT A SCAN. MEASURED (16 Oct 2026, frame times on two copies):
    the host's poll read every paintable wall and piece of furniture every 2 s
    - 25 to 58 ms of one frame, a stutter on the host and so on every guest. A
    skin or a mesh only changes through the component's own Load Material,
    Load Asset or Manual Load Asset (Wall @1459-@2404, Shelve @1555), so those
    are hooked: the scan runs once something was repainted or placed, and in
    full every FULL_EVERY and for a new guest. Without the hooks (not loaded
    yet, or not hookable) it polls as before.
]]
local CHANGE_FNS = {
    "/Game/VideoStore/core/blueprint/AC_MeshSkin.AC_MeshSkin_C:Load Material",
    "/Game/VideoStore/core/blueprint/AC_MeshSkin.AC_MeshSkin_C:Load Asset",
    "/Game/VideoStore/core/blueprint/AC_MeshSkin.AC_MeshSkin_C:Manual Load Asset",
    "/Game/VideoStore/core/blueprint/AC_MeshSkin_Shelve.AC_MeshSkin_Shelve_C:Load Material",
    "/Game/VideoStore/core/blueprint/AC_MeshSkin_Shelve.AC_MeshSkin_Shelve_C:Load Asset",
    "/Game/VideoStore/core/blueprint/AC_MeshSkin_Shelve.AC_MeshSkin_Shelve_C:Manual Load Asset",
}
local dirty = false           -- host: something changed since the last scan
local hookedFns = {}          -- path -> function address hooked
local nextHookTry = 0

local function hookChanges(now)
    if now < nextHookTry then return end
    nextHookTry = now + 5
    for _, path in ipairs(CHANGE_FNS) do
        local f = StaticFindObject(path)
        local addr = nil
        if UE.valid(f) then pcall(function() addr = f:GetAddress() end) end
        if addr and hookedFns[path] ~= addr then
            if pcall(function()
                RegisterHook(path, function() dirty = true end)
            end) then
                hookedFns[path] = addr
            end
        end
    end
end

local cfg = nil
local stats = { sent = 0, received = 0, applied = 0, unmatched = 0,
                titlesSent = 0, titlesReceived = 0, titlesApplied = 0 }

--------------------------------------------------------------------------
-- Both sides
--------------------------------------------------------------------------

--- Every AC_MeshSkin owner here: { actor, cls, loc, comp }.
local function owners()
    local out = {}
    for _, base in ipairs(OWNERS) do
        for _, a in ipairs(UE.findAll(base) or {}) do
            if UE.alive(a) then
                local comp = UE.TryGet(a, "AC_MeshSkin")
                local loc = nil
                pcall(function() loc = UE.vec(a:K2_GetActorLocation()) end)
                if UE.valid(comp) and loc and loc.Z > HIDDEN_BELOW then
                    out[#out + 1] = { actor = a, cls = UE.ClassNameOf(a), loc = loc,
                                      comp = comp, wall = (base == "Wall_C") }
                end
            end
        end
    end
    return out
end

local function keyOf(cls, loc)
    return ("%s;%.0f;%.0f;%.0f"):format(cls, loc.X, loc.Y, loc.Z)
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local lastSent  = {}     -- key -> "mesh;skin" as last sent
local lastPoll  = 0
local lastFull  = -1e9
local lastGuests = 0

local function guestCount()
    local n = 0
    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        if UE.alive(pc) and not UE.IsLocalController(pc) then n = n + 1 end
    end
    return n
end

local function send(msgType, entries)
    local sent = 0
    for i = 1, #entries, CHUNK do
        local payload = {}
        for j = i, math.min(i + CHUNK - 1, #entries) do
            payload["e" .. (j - i + 1)] = entries[j]
        end
        if Chan.broadcast(msgType, payload) > 0 then sent = sent + 1 end
    end
    return sent
end

local finishMeshChoices
local sendTitles, tickTitles      -- shelf titles, defined further down

function SkinSync.tickHost(now)
    if not UE.IsServer() then return end
    finishMeshChoices()
    hookChanges(now)
    if now - lastPoll < POLL_EVERY then return end
    lastPoll = now

    local guests = guestCount()
    if guests == 0 then
        lastSent, lastGuests = {}, 0
        return
    end
    -- A new guest has seen nothing yet: everything, now and again in 30 s.
    local full = guests > lastGuests or (now - lastFull) > FULL_EVERY
    -- The next poll after a change: by then the repaint's own loading is done.
    if not full and next(hookedFns) ~= nil and not dirty then return end
    dirty = false
    stats.scans = (stats.scans or 0) + 1
    lastGuests = guests

    local current, entries = {}, {}
    for _, o in ipairs(owners()) do
        local m = UE.TryGet(o.comp, "Current Mesh Use")
        local s = UE.TryGet(o.comp, "Current Skin Use")
        if type(m) == "number" and type(s) == "number" then
            local key, val = keyOf(o.cls, o.loc), ("%d;%d"):format(m, s)
            current[key] = val
            if full or lastSent[key] ~= val then entries[#entries + 1] = key .. ";" .. val end
        end
    end
    if full then lastFull = now end
    lastSent = current
    if #entries > 0 then stats.sent = stats.sent + send("skins", entries) end
    sendTitles(full)
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local pending  = {}      -- key -> { cls, x, y, z, m, s, since }
local applied  = {}      -- actor path -> "mesh;skin" this mod applied
local nextResolve = 0

local function onSkins(fields)
    stats.received = stats.received + 1
    local now = os.clock()
    for _, v in pairs(fields) do
        local cls, x, y, z, m, s = tostring(v):match("^([^;]+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+)$")
        if cls then
            pending[("%s;%s;%s;%s"):format(cls, x, y, z)] = {
                cls = cls, x = tonumber(x), y = tonumber(y), z = tonumber(z),
                m = tonumber(m), s = tonumber(s), since = now }
        end
    end
    nextResolve = 0
end

local function pathOf(a)
    local p = UE.pathOf(a)
    if p then return p end
    local ok, n = pcall(function() return a:GetFullName() end)
    return ok and n or nil
end

--- Dress one object with the host's numbers. Returns true when it is done.
local function apply(o, m, s)
    local path = pathOf(o.actor)
    if not path then return false end
    local want = ("%d;%d"):format(m, s)
    if applied[path] == want then return true end

    local curM = UE.TryGet(o.comp, "Current Mesh Use")
    local curS = UE.TryGet(o.comp, "Current Skin Use")
    local before = applied[path]

    -- Furniture dresses itself at BeginPlay with the numbers it was
    -- replicated (Shelve: Manual Load Asset). If those are already the
    -- host's, it shows the host's look and reloading it would only flicker.
    if not o.wall and before == nil and curM == m and curS == s then
        applied[path] = want
        return true
    end

    UE.TrySet(o.comp, "Current Mesh Use", m)
    UE.TrySet(o.comp, "Current Skin Use", s)
    local ok
    if o.wall then
        -- The wall's own handler sets the mesh and picks the skin, but only
        -- while this is false; once true it resets the skin to 0 instead
        -- (bp/Wall.txt @1637).
        UE.TrySet(o.comp, "Savegame data loaded", false)
        ok = UE.TryCall(o.comp, "Load Asset", false)
    else
        local meshBefore = before and tonumber(before:match("^(%-?%d+)")) or curM
        if meshBefore ~= m or before == nil then
            ok = UE.TryCall(o.comp, "Manual Load Asset")
        else
            ok = UE.TryCall(o.comp, "Load Material")
        end
    end
    if not ok then return false end
    applied[path] = want
    stats.applied = stats.applied + 1
    return true
end

function SkinSync.tickGuest(now)
    if not UE.IsClient() then return end
    tickTitles(now)
    if next(pending) == nil or now < nextResolve then return end
    nextResolve = now + RESOLVE_EVERY

    local here = owners()
    local byClass = {}
    for _, o in ipairs(here) do
        local list = byClass[o.cls]
        if not list then list = {} byClass[o.cls] = list end
        list[#list + 1] = o
    end

    local t = os.clock()
    for key, e in pairs(pending) do
        local best, bd = nil, MATCH_DIST
        for _, o in ipairs(byClass[e.cls] or {}) do
            local dx, dy, dz = o.loc.X - e.x, o.loc.Y - e.y, o.loc.Z - e.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d < bd then best, bd = o, d end
        end
        if best then
            if apply(best, e.m, e.s) then pending[key] = nil end
        elseif t - e.since > GIVE_UP_AFTER then
            -- Not here (yet): an object outside this guest's relevancy, or one
            -- the host just moved. The host resends everything every 30 s.
            pending[key] = nil
            stats.unmatched = stats.unmatched + 1
        end
    end
end

--------------------------------------------------------------------------
-- A guest's choice in the skin picker (guestinput.lua carries it)
--------------------------------------------------------------------------

--- The skinned object at this spot, or nil. The picker names an actor on
--- the guest's machine; the host finds its own copy the same way the guest
--- finds the host's (class does not travel: the place is enough at 8 cm).
function SkinSync.ownerAt(loc)
    local best, bd = nil, MATCH_DIST
    for _, o in ipairs(owners()) do
        local dx, dy, dz = o.loc.X - loc.X, o.loc.Y - loc.Y, o.loc.Z - loc.Z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < bd then best, bd = o, d end
    end
    return best
end

local skinAfterMesh = {}   -- actor path -> true: give it skin 0 next tick

--- Host: apply a guest's choice exactly as the picker does on the machine
--- that opened it (UI_SkinMode "Material Selected_Event", @4798): the mesh
--- tool sets the mesh and, a tick later, skin 0; the skin tool sets the skin.
--- Both are replicated, and the poll above sends them to every guest.
function SkinSync.choose(loc, tool, id)
    local o = SkinSync.ownerAt(loc)
    if not o then return false end
    if tool == 2 then
        if not UE.TryCall(o.actor, "Set new Mesh", id) then return false end
        local path = pathOf(o.actor)
        if path then skinAfterMesh[path] = true end
    else
        if not UE.TryCall(o.actor, "Set new Skin", id) then return false end
    end
    lastPoll = 0             -- send it now, not in up to two seconds
    return true
end

--- The tick after a mesh change (the picker's DelayUntilNextTick). Declared
--- above tickHost, which calls it.
function finishMeshChoices()
    if next(skinAfterMesh) == nil then return end
    local paths = skinAfterMesh
    skinAfterMesh = {}
    for path in pairs(paths) do
        local a = UE.findObject(path)
        if UE.alive(a) then UE.TryCall(a, "Set new Skin", 0) end
    end
end

--------------------------------------------------------------------------
-- Shelf titles and text signs
--------------------------------------------------------------------------
--[[
    REPORTED: the signs over the shelves read "Default Text" on a guest.
    Two kinds of sign, both set up from the host's save and nowhere else:

      * TextSign_C, the sign a player writes ("CHRISTMAS", "SNACKS",
        "HORROR" in the test save). Its words are "User Text", which only
        its Load sets - from the save's TextSign map, by the sign's GUID
        (bp/TextSign.txt @1192) - and Update Text draws (@1811). A guest
        never loads the save, so every one read the TextRender's default.
        MEASURED: 6 of 6 placed signs had words on the host, none on the
        guest.
      * ShelveTitle_C, the genre card each shelf carries (73 in the test
        save). It shows three values the shelf hands it, Update Material
        (Genre, Special Tag, Empty Shelf) (bp/ShelveTitle.txt @1901), which
        pick the card's tile; the shelf works them out from the tapes its
        containers hold (Shelve "Checking for Film Genre", @7780). On a guest
        the containers hold nothing - which tape is stored where is a
        Blueprint variable, never replicated - so every card came out empty,
        genre 0.

      * PosterFrame_C (and the standing and small frames), a film poster with
        its title under it. The film is "Specific SKU", from the save (Load
        -> PosterFrame struct, @342) or the player's pick in its SKU menu;
        Apply Material for Film based on SKU draws it (@4081), and with SKU 0
        it rolls a random film (Create Film Data). The skins' Materials Loaded
        runs that on a guest too - with 0, so every poster showed a film of
        its own choosing.

    The host sends each sign's words, each card's values and each poster's
    film, matched by place and facing (a double-sided shelf has two cards at one spot, facing
    opposite ways - 3 such pairs in the test save), and the guest hands them
    to the sign's own Update Text and the card's own Update Material. A
    guest's own shelf can work its genre out again later (a container event
    on the guest), so the guest checks every few seconds and applies the
    host's values again where they slipped.
]]

local TITLE, SIGN, POSTER = "ShelveTitle_C", "TextSign_C", "PosterFrame_C"
local TITLE_VERIFY_EVERY = 10.0   -- guest: re-check what is already dressed
local TITLE_FORGET_AFTER = 75.0   -- guest: a place the host has not named for this long is gone
                                  -- (the host names every sign every 30 s)

local function truthy(v) return v == true or v == 1 end

local function textString(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end

--- What a card shows now, as sent: "genre;tag;empty;visible", or nil.
local function titleState(a)
    local g, t = UE.TryGet(a, "Genre"), UE.TryGet(a, "Special Tag")
    if type(g) ~= "number" or type(t) ~= "number" then return nil end
    local e = truthy(UE.TryGet(a, "Empty Shelf"))
    -- Its class default is true; anything but an explicit false is shown.
    local v = UE.TryGet(a, "Shelf Title Visiblity") ~= false
    return ("%d;%d;%d;%d"):format(g, t, e and 1 or 0, v and 1 or 0)
end

--- What a text sign says now, or nil.
local function signState(a) return textString(UE.TryGet(a, "User Text")) end

--- Which film a poster shows now, or nil while it has none picked.
local function posterState(a)
    local sku = UE.TryGet(a, "Specific SKU")
    if type(sku) ~= "number" or sku == 0 then return nil end
    return ("%d"):format(sku)
end

--- Every sign of a class in the store: { actor, loc, yaw }. Packed ones
--- (below the floor) are left out.
local function placed(cls)
    local out = {}
    for _, a in ipairs(UE.findAll(cls) or {}) do
        if UE.alive(a) then
            local loc, rot = nil, nil
            pcall(function()
                loc = UE.vec(a:K2_GetActorLocation())
                rot = UE.rot(a:K2_GetActorRotation())
            end)
            if loc and loc.Z > HIDDEN_BELOW then
                out[#out + 1] = { actor = a, loc = loc, yaw = rot and rot.Yaw or 0 }
            end
        end
    end
    return out
end

local function yawApart(a, b)
    local d = (a - b) % 360
    return d > 180 and 360 - d or d
end

local function placeKey(o)
    return ("%.0f;%.0f;%.0f;%.0f"):format(o.loc.X, o.loc.Y, o.loc.Z, o.yaw % 360)
end

-- Host --------------------------------------------------------------------

local lastTitles, lastSigns, lastPosters = {}, {}, {}   -- place -> what was last sent

local function changes(cls, stateOf, last, full)
    local current, entries = {}, {}
    for _, o in ipairs(placed(cls)) do
        local val = stateOf(o.actor)
        if val then
            local key = placeKey(o)
            current[key] = val
            if full or last[key] ~= val then entries[#entries + 1] = key .. ";" .. val end
        end
    end
    return current, entries
end

--- Called from tickHost's poll (every 2 s, and everything when a guest
--- arrives and every 30 s). Declared at the top of the file.
function sendTitles(full)
    local entries
    lastTitles, entries = changes(TITLE, titleState, lastTitles, full)
    if #entries > 0 then stats.titlesSent = stats.titlesSent + send("titles", entries) end
    lastSigns, entries = changes(SIGN, signState, lastSigns, full)
    if #entries > 0 then stats.titlesSent = stats.titlesSent + send("signs", entries) end
    lastPosters, entries = changes(POSTER, posterState, lastPosters, full)
    if #entries > 0 then stats.titlesSent = stats.titlesSent + send("posters", entries) end
end

-- Guest -------------------------------------------------------------------

local want = { [TITLE] = {}, [SIGN] = {}, [POSTER] = {} }   -- class -> place -> { x, y, z, yaw, val, since }
local VALID = { [TITLE] = "^%d+;%d+;[01];[01]$", [POSTER] = "^%d+$" }   -- a sign's words are anything
local done = {}                              -- sign path -> the value this mod applied
local nextTitleCheck, titlesDirtySince = 0, nil

local function onPlaces(cls, fields)
    stats.titlesReceived = stats.titlesReceived + 1
    local now = os.clock()
    for _, v in pairs(fields) do
        local x, y, z, yaw, val = tostring(v):match("^(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+);(.*)$")
        if x and (VALID[cls] == nil or val:match(VALID[cls])) then
            want[cls][("%s;%s;%s;%s"):format(x, y, z, yaw)] = {
                x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw),
                val = val, since = now }
        end
    end
    titlesDirtySince = titlesDirtySince or now
    nextTitleCheck = 0
end

--- A card: Update Material the first time this mod meets it (the guest's
--- own may never have dressed it at all), afterwards only where its values
--- differ from the host's; whether it is shown, on its own.
local function dressTitle(a, val, first)
    local g, t, e, v = val:match("^(%d+);(%d+);([01]);([01])$")
    g, t, e, v = tonumber(g), tonumber(t), e == "1", v == "1"
    local cur = titleState(a)
    if first or not cur or cur:sub(1, -3) ~= val:sub(1, -3) then
        if not UE.TryCall(a, "Update Material", g, t, e) then return false end
        stats.titlesApplied = stats.titlesApplied + 1
    end
    if (UE.TryGet(a, "Shelf Title Visiblity") ~= false) ~= v then
        UE.TryCall(a, "Shelve Title Visiblity", v)
    end
    return true
end

--- A text sign: the words, then its own Update Text (the size, and the
--- colour of its skin, come with it).
local function dressSign(a, val, first)
    if not first and signState(a) == val then return true end
    -- UE.setText: a plain FText write runs 8 bytes past "User Text" into the
    -- sign's "UI Text Command" pointer (ue.lua).
    if not UE.setText(a, "User Text", val) then return false end
    if not UE.TryCall(a, "Update Text") then return false end
    stats.titlesApplied = stats.titlesApplied + 1
    return true
end

--- A poster: the host's film, drawn by its own Apply Material for Film based
--- on SKU (the picture loads asynchronously, the title follows it).
local function dressPoster(a, val, first)
    if not first and posterState(a) == val then return true end
    if not UE.TrySet(a, "Specific SKU", tonumber(val)) then return false end
    if not UE.TryCall(a, "Apply Material for Film based on SKU", false) then return false end
    stats.titlesApplied = stats.titlesApplied + 1
    return true
end

local DRESS = { [TITLE]  = { state = titleState,  dress = dressTitle },
                [SIGN]   = { state = signState,   dress = dressSign },
                [POSTER] = { state = posterState, dress = dressPoster } }

--- Declared at the top of the file; tickGuest calls it every tick.
function tickTitles(now)
    if next(want[TITLE]) == nil and next(want[SIGN]) == nil and next(want[POSTER]) == nil then return end
    if now < nextTitleCheck then return end
    -- Ages on os.clock(), the clock onPlaces stamps with (as the skins do).
    local t = os.clock()
    local dirty = titlesDirtySince ~= nil and (t - titlesDirtySince) < GIVE_UP_AFTER
    nextTitleCheck = now + (dirty and RESOLVE_EVERY or TITLE_VERIFY_EVERY)

    local unfinished = 0
    for cls, wants in pairs(want) do
        -- Each sign gets the newest entry within reach that faces its way: a
        -- shelf the host moved leaves its old place behind until that is
        -- forgotten, and one put down where another stood must not be given
        -- the old one's values.
        local here = placed(cls)
        local pick = {}
        for key, w in pairs(wants) do
            if t - w.since > TITLE_FORGET_AFTER then
                wants[key] = nil
            else
                local best, bd = nil, MATCH_DIST
                for i, o in ipairs(here) do
                    local dx, dy, dz = o.loc.X - w.x, o.loc.Y - w.y, o.loc.Z - w.z
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d < bd and yawApart(o.yaw, w.yaw) < 5 then best, bd = i, d end
                end
                if best then
                    if not pick[best] or pick[best].since < w.since then pick[best] = w end
                else
                    unfinished = unfinished + 1
                end
            end
        end
        local d = DRESS[cls]
        for i, w in pairs(pick) do
            local a = here[i].actor
            local path = pathOf(a)
            if path and done[path] == w.val and d.state(a) == w.val then
                -- as the host has it, and this mod already saw to it
            elseif path and d.dress(a, w.val, done[path] == nil) then
                done[path] = w.val
            else
                unfinished = unfinished + 1
            end
        end
    end
    -- Keep looking quickly while some are not here yet (still arriving over
    -- replication), for as long as the skins do.
    if unfinished == 0 then titlesDirtySince = nil end
end

--------------------------------------------------------------------------

function SkinSync.stats() return stats end

--- Back to single player, or a new session: nothing applied here still holds.
function SkinSync.reset()
    lastSent, lastPoll, lastFull, lastGuests = {}, 0, -1e9, 0
    pending, applied, nextResolve = {}, {}, 0
    skinAfterMesh = {}
    lastTitles, lastSigns, lastPosters, done = {}, {}, {}, {}
    want = { [TITLE] = {}, [SIGN] = {}, [POSTER] = {} }
    nextTitleCheck, titlesDirtySince = 0, nil
end

function SkinSync.init(config)
    cfg = config
    Chan.on("skins", function(fields) Log.guard("skin sync", onSkins, fields) end)
    Chan.on("titles", function(fields)
        if UE.IsServer() then return end
        Log.guard("shelf titles", onPlaces, TITLE, fields)
    end)
    Chan.on("signs", function(fields)
        if UE.IsServer() then return end
        Log.guard("text signs", onPlaces, SIGN, fields)
    end)
    Chan.on("posters", function(fields)
        if UE.IsServer() then return end
        Log.guard("posters", onPlaces, POSTER, fields)
    end)
end

return SkinSync
