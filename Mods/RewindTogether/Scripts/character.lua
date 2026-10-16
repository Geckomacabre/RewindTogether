--[[
    Rewind Together - choosing your character

    REQUESTED (16 Oct 2026): "can we give people the option to choose their
    character when they first start a store", then "make the character select
    show all possible characters and let people pick one", and "make it like
    the developers made it themselves".

    Everybody's body is a town character's (bodies.lua): until now the host
    picked one for each player, a different one every session. Now each player
    makes their own on the character screen (charscreen.lua: the game's own
    menu, buttons and font; every choice the game itself has, and its 14 named
    regulars; creator.lua). It opens:
      * by itself the first time someone plays with the mod, a few seconds
        after their store (or their friend's) has loaded;
      * from the pause menu ("Character", pausemenu.lua);
      * with Config.Keys.ChooseCharacter (F4).
    What is made is kept in a file next to the game (RewindTogether.character
    .txt: the look, and the choices it was made from, so the screen opens on
    it again) and is how that player looks to everyone.

    ONE CHARACTER PER STORE. REQUESTED (16 Oct 2026): "i want it to save the
    character i make per save". A store is one host's save slot - the
    GameMode's "Save Slot Name" (Core_Gamemode @13660, from the GameInstance's
    "Save Slot" the main menu set) on the machine that hosts it - and is
    known by a short key made from the host's Steam ID (or name) and that
    slot, the same key on every player's machine: the host works it out and
    tells its guests ("chr"). The file keeps a character for each store it
    has been in; the first time in a store the screen opens by itself, on
    the character last made, so DONE keeps that one for this store too. The
    pause menu's Character and F4 change this store's at any time.

    Getting a guest's choice to the host. A look is asset paths, a kilobyte
    or two of text, and guest -> host has only ever carried six numbers
    (rpcchan.lua: ServerSetSpectatorLocation). APlayerController's
    ServerNotifyLoadedWorld(FName) is a reliable server call that does
    nothing for a name that is not the world the server is in (it compares
    WorldPackageName with the world's package and stops). rpcchan.lua turned
    it down for traffic because every FName is kept for the life of the
    process - right for a stream, harmless for one look per session. So the
    guest sends its look as a few names ("RTLK:<n>/<of>:<piece>", a name
    holds 1023 characters) once when it joins; the host puts them together
    and dresses that player in it everywhere (Bodies.chooseLook).
]]

local Log     = require("log")
local UE      = require("ue")
local P2P     = require("steamp2p")
local Creator = require("creator")
local Screen  = require("charscreen")

local Character = {}

local FILE        = "RewindTogether.character.txt"   -- next to the game, like the log
local PREFIX      = "RTLK:"
local PIECE       = 800        -- characters of look per name
local NOTIFY_FN   = "/Script/Engine.PlayerController:ServerNotifyLoadedWorld"
local RESEND      = 15.0       -- guest: the host has not dressed us in it yet - again
local MAX_SENDS   = 3
local FIRST_WAIT  = 10.0       -- seconds after the pawn appears before the first-time screen
local LOOK_KEYS   = { "m", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "h", "hm", "f", "fm", "a", "am",
                      "e", "eb", "cs" }

local STORE_EVERY = 3.0        -- host: whose store this is, to the guests; and looked at again
local saved = nil              -- my look in this store (nil: the host picks)
local savedSpec = nil          -- the choices it was made from
local asked = true             -- this store's screen has been shown (no store yet: nothing to ask)
local last, lastSpec = nil, nil  -- the look I made last, anywhere: a new store's screen opens on it
local stores = {}              -- store key -> { look, spec, label }: every store's, kept in the file
local store, storeLabel = nil, nil  -- the store I am in (host: worked out; guest: the host says)
local heard = nil              -- guest: { k, l } from the host, not entered yet
local unsaved = nil            -- { look, spec } chosen before the store was known
local storeAt = -1e9           -- host: when the store was last looked at / told
local sends, sentAt = 0, nil   -- guest: this session
local appliedHost = nil        -- host: the PlayerId my look was given to
local pawnSince = nil
local openAt = nil             -- open the screen at this time (pause menu: after it has closed)
local inbox = {}               -- host: { pc = full name, s = name } from the hook
local routes = {}              -- host: other users of this route: prefix -> fn(pc full name, rest)
local routed = {}              -- host: { pc, prefix, s } for them, from the hook
local pieces = {}              -- host: pc full name -> { of = n, got = { [i] = piece } }
local hooked = false
local stats = { picked = 0, sent = 0, received = 0, applied = 0 }

--------------------------------------------------------------------------
-- The file
--------------------------------------------------------------------------

--[[
    The file: the look made last at the top (1.8.0 wrote only that, so its
    file reads the same), then one section per store:

        [store 1a2b3c4d]
        label=save 1
        m=...            (no look: the host picks for me there)
]]
local function lookFrom(fields)
    if (fields.m or "") == "" then return nil end
    local look = {}
    for _, k in ipairs(LOOK_KEYS) do if fields[k] then look[k] = fields[k] end end
    return look
end

--- The last look, its choices, and every store's: { [key] = { look, spec, label } }.
local function load()
    local ok, fh = pcall(io.open, FILE, "r")
    if not ok or not fh then return nil, nil, {} end
    local top, sections, cur = {}, {}, nil
    for line in fh:lines() do
        local key = line:match("^%[store (%x+)%]%s*$")
        if key then
            cur = {}
            sections[key] = cur
        else
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k then (cur or top)[k] = v end
        end
    end
    fh:close()
    local all = {}
    for key, f in pairs(sections) do
        local look = lookFrom(f)
        all[key] = { look = look, spec = look and Creator.fromFields(f) or nil, label = f.label }
    end
    local look = lookFrom(top)
    return look, look and Creator.fromFields(top) or nil, all
end

local function writeFields(fh, fields)
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        fh:write(k, "=", (tostring(fields[k]):gsub("[\r\n]", " ")), "\n")
    end
end

local function fieldsOf(look, spec, into)
    into = into or {}
    if look then for _, k in ipairs(LOOK_KEYS) do if look[k] then into[k] = look[k] end end end
    if look and spec then Creator.toFields(spec, into) end
    return into
end

local function save()
    local ok, fh = pcall(io.open, FILE, "w")
    if not ok or not fh then return false end
    fh:write("# Rewind Together: what you look like to the other players, in each store.\n")
    fh:write("# Change it in game: the pause menu's Character, or F4.\n")
    writeFields(fh, fieldsOf(last, lastSpec))
    local keys = {}
    for k in pairs(stores) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local e = stores[k]
        fh:write("\n[store ", k, "]\n")
        writeFields(fh, fieldsOf(e.look, e.spec, { label = e.label or "" }))
    end
    fh:close()
    return true
end

--- A store's key: the same on every player's machine (FNV-1a of who hosts
--- it and the save slot), so nothing about the host is kept in the file.
local function keyOf(s)
    local h = 2166136261
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) % 4294967296 end
    return ("%08x"):format(h)
end

local function slotLabel(slot) return (slot:gsub("^Player_Save(%d+)$", "save %1")) end

--- Host (and single player): the store being played, from the GameMode.
local function hostStore()
    local gm = UE.GetGameMode()
    if not (UE.valid(gm) and UE.ClassNameOf(gm) == "Core_Gamemode_C") then return nil end
    local slot = UE.TryGet(gm, "Save Slot Name")
    if type(slot) ~= "string" then
        local s = nil
        pcall(function() s = slot:ToString() end)
        slot = s
    end
    if type(slot) ~= "string" or slot == "" then return nil end
    local who = nil
    pcall(function() who = require("net").getLocalSteamId() end)
    who = who or UE.PlayerNameOf(UE.GetPlayerController()) or "host"
    return keyOf(tostring(who) .. "/" .. slot), slot
end

--- In this store from now: its own look, or - the first time here - the
--- last one made, worn while the screen asks.
local function enter(key, label)
    if key == store then return end
    store, storeLabel = key, label
    local e = stores[key]
    if not e and unsaved then
        e = { look = unsaved.look, spec = unsaved.spec, label = label }
        stores[key], unsaved = e, nil
        save()
    end
    if e then
        saved, savedSpec, asked = e.look, e.spec, true
        if label and label ~= "" and e.label ~= label then e.label = label save() end
    else
        saved, savedSpec, asked = last, lastSpec, false
    end
    appliedHost, sends, sentAt = nil, 0, nil
    Log.info("character: in %s - %s", label or ("store " .. key), e and (e.look and "your character for it"
             or "the host picks how you look") or "the first time here")
end

--- What this store has now (the screen was shown: asked).
local function keep()
    asked = true
    if store then stores[store] = { look = saved, spec = savedSpec, label = storeLabel } end
    save()
end

--- What I look like (nil: the host picks).
function Character.saved() return saved end

local function tell(text, seconds)
    Log.info("character: %s", (text:gsub("{br}", " - ")))
    local shown = false
    pcall(function() shown = require("hud").notice(text, false, seconds or 6) end)
    if not shown then pcall(function() require("chat").notice((text:gsub("{br}", " - "))) end) end
end

local function myId()
    local pc = UE.GetPlayerController()
    local ps = UE.valid(pc) and UE.TryGet(pc, "PlayerState") or nil
    return UE.valid(ps) and tonumber(UE.TryGet(ps, "PlayerId")) or nil
end

--------------------------------------------------------------------------
-- Wearing it
--------------------------------------------------------------------------

--- A guest: its look to the host, a few names long.
local function sendToHost(look)
    local pc = UE.GetPlayerController()
    if not UE.alive(pc) then return false end
    local s = P2P.encode("mylook", look)
    local n = math.ceil(#s / PIECE)
    local ok = true
    for i = 1, n do
        local name = ("%s%d/%d:%s"):format(PREFIX, i, n, s:sub((i - 1) * PIECE + 1, i * PIECE))
        ok = pcall(function() pc:ServerNotifyLoadedWorld(FName(name)) end) and ok
    end
    if ok then
        sends, sentAt = sends + 1, os.clock()
        stats.sent = stats.sent + 1
    end
    return ok
end

--- This look is mine now: kept, and worn for everyone.
local function wear(look, spec)
    saved, savedSpec, asked = look, spec, true
    last, lastSpec = look, spec
    if store then
        stores[store] = { look = look, spec = spec, label = storeLabel }
    else
        unsaved = { look = look, spec = spec }     -- the store it is for is not known yet
    end
    save()
    stats.picked = stats.picked + 1
    if UE.IsServer() and not UE.IsStandalone() then
        local id = myId()
        if id then require("bodies").chooseLook(id, look, "the host's own choice") appliedHost = id end
    elseif UE.IsClient() then
        sends = 0
        sendToHost(look)
    end
end

--- Open the character screen (F4, the pause menu, the first time).
function Character.choose()
    if Screen.isOpen() then return true end
    local spec = savedSpec or lastSpec or Creator.random()
    local ok = Screen.open(spec, function(look, made)
        wear(look, made)
        tell(UE.IsStandalone() and "saved for this store - this is how your friends will see you here"
             or "saved for this store - this is how everyone sees you here", 5)
    end, function()
        -- Not chosen: this store keeps what is worn (the last one made).
        if not asked then keep() end
    end)
    if ok and not asked then keep() end
    return ok
end

--- From the pause menu: once it has closed (its Close ESC finishes a tick later).
function Character.chooseSoon()
    openAt = os.clock() + 0.35
end

--- Escape (a guest has no game Escape for this menu - pausemenu.lua).
local escapedAt = nil
function Character.escape()
    if Screen.isOpen() then
        escapedAt = os.clock()
        Screen.cancel()
        return true
    end
    return false
end

--- That Escape was this screen's (pausemenu.lua must not open a menu on it).
function Character.escapedRecently() return escapedAt ~= nil and (os.clock() - escapedAt) < 0.5 end

function Character.isOpen() return Screen.isOpen() end

--- rt.character clear: back to the host's pick.
function Character.clear()
    saved, savedSpec = nil, nil
    keep()
    tell("character choice cleared for this store - the host picks how you look here")
end

--------------------------------------------------------------------------
-- Host: guests' choices arriving
--------------------------------------------------------------------------

local function hook()
    if hooked then return end
    hooked = pcall(function()
        RegisterHook(NOTIFY_FN, function(ctx, name)
            if not UE.IsServer() then return end
            local s, pcName = nil, nil
            pcall(function() s = name:get():ToString() end)
            if type(s) ~= "string" then return end
            if s:sub(1, #PREFIX) ~= PREFIX then
                for prefix in pairs(routes) do
                    if s:sub(1, #prefix) == prefix then
                        pcall(function() pcName = ctx:get():GetFullName() end)
                        if pcName and #routed < 16 then
                            routed[#routed + 1] = { pc = pcName, prefix = prefix, s = s:sub(#prefix + 1) }
                        end
                    end
                end
                return
            end
            pcall(function() pcName = ctx:get():GetFullName() end)
            -- Queued: put together and used from the tick, never inside a hook.
            if pcName and #inbox < 64 then inbox[#inbox + 1] = { pc = pcName, s = s } end
        end)
    end)
end

local function controllerNamed(name)
    for _, pc in ipairs(UE.GetAllPlayerControllers() or {}) do
        if UE.alive(pc) and pc:GetFullName() == name then return pc end
    end
    return nil
end

local function takeInbox()
    if #inbox == 0 then return end
    local batch = inbox
    inbox = {}
    for _, m in ipairs(batch) do
        local i, n, piece = m.s:match("^" .. PREFIX .. "(%d+)/(%d+):(.*)$")
        i, n = tonumber(i), tonumber(n)
        if i and n and n >= 1 and n <= 16 and i <= n then
            local p = pieces[m.pc]
            if not p or p.of ~= n then p = { of = n, got = {} } pieces[m.pc] = p end
            p.got[i] = piece
            local whole, have = {}, 0
            for k = 1, n do
                if p.got[k] then have, whole[k] = have + 1, p.got[k] end
            end
            if have == n then
                pieces[m.pc] = nil
                local msgType, look = P2P.decode(table.concat(whole))
                local pc = controllerNamed(m.pc)
                local ps = pc and UE.TryGet(pc, "PlayerState") or nil
                local id = UE.valid(ps) and tonumber(UE.TryGet(ps, "PlayerId")) or nil
                if msgType == "mylook" and look and (look.m or "") ~= "" and id then
                    stats.received = stats.received + 1
                    require("bodies").chooseLook(id, look, "their own choice")
                    Log.info("character: %s chose how they look - everyone sees them so",
                             UE.PlayerNameOf(pc) or "a guest")
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------

--- Somewhere the screen can open without getting in the way: not at a
--- machine or the till, not in a conversation, not at the end of the day.
local function freeToOpen()
    local G = require("guestinput")
    if G.inMachine() or G.atTill() then return false end
    if require("talksync").guestTalking() then return false end
    local gm = UE.GetGameMode()
    local summary = UE.valid(gm) and UE.TryGet(gm, "End of Day Interface") or nil
    if UE.valid(summary) then return false end
    local pawn = UE.GetPawn()
    local menu = UE.valid(pawn) and UE.TryGet(pawn, "UI ESC MENU") or nil
    local up = false
    if UE.valid(menu) then pcall(function() up = menu:IsInViewport() end) end
    return not up
end

--- Which store this is: the host's own reading, told to its guests; a
--- guest's from the host.
local function whichStore(now)
    if UE.IsServer() then
        if (now - storeAt) < STORE_EVERY then return end
        storeAt = now
        local key, slot = hostStore()
        if not key then return end
        enter(key, slotLabel(slot))
        if not UE.IsStandalone() then
            local who = UE.PlayerNameOf(UE.GetPlayerController())
            require("rpcchan").broadcast("chr", { k = key, l = (who and (who .. "'s ") or "a friend's ") .. slotLabel(slot) })
        end
    elseif heard then
        enter(heard.k, heard.l)
        heard = nil
    end
end

function Character.tick(now)
    hook()
    whichStore(now)
    if UE.IsServer() then
        takeInbox()
        if #routed > 0 then
            local batch = routed
            routed = {}
            for _, m in ipairs(batch) do
                if routes[m.prefix] then Log.guard("a name from a guest", routes[m.prefix], m.pc, m.s) end
            end
        end
    end
    Screen.tick()
    local pawn = UE.GetPawn()
    if not UE.alive(pawn) then
        pawnSince = nil
        return
    end
    pawnSince = pawnSince or now

    if openAt and os.clock() >= openAt then
        openAt = nil
        Character.choose()
    end
    -- The first time in this store: the screen by itself, once the store is up.
    if store and not asked and not Screen.isOpen() and (now - pawnSince) > FIRST_WAIT and freeToOpen() then
        Log.info("character: first time in this store - the character screen")
        Character.choose()
    end
    if not saved then return end

    if UE.IsServer() and not UE.IsStandalone() then
        local id = myId()
        local B = require("bodies")
        if id and (appliedHost ~= id or not B.sameLook(B.lookOf(id), saved)) then
            appliedHost = id
            B.chooseLook(id, saved, "the host's own choice")
            stats.applied = stats.applied + 1
        end
    elseif UE.IsClient() and require("rpcchan").isReady() then
        -- Sent when the session starts; again while the host has not used it.
        local id = myId()
        local B = require("bodies")
        local worn = id ~= nil and B.sameLook(B.lookOf(id), saved)
        if not worn and sends < MAX_SENDS and (sentAt == nil or (now - sentAt) > RESEND) then
            sendToHost(saved)
        end
    end
end

function Character.report()
    local n = 0
    for _ in pairs(stores) do n = n + 1 end
    local lines = { ("Character: %s in %s (%d store(s) kept); picked %d, sent %d, received %d, host's own applied %d"):format(
        saved and ("chosen (" .. ((saved.m or ""):match("([^/%.]+)$") or "?") .. ")")
        or "not chosen (the host picks)", store and (storeLabel or store) or "no store yet", n,
        stats.picked, stats.sent, stats.received, stats.applied) }
    for _, l in ipairs(Screen.report()) do lines[#lines + 1] = l end
    return lines
end

--- In or out of a session: send again, apply again, and find out again
--- whose store this is (what was chosen is kept).
function Character.reset()
    Screen.reset()
    sends, sentAt, appliedHost, pawnSince, openAt = 0, nil, nil, nil, nil
    inbox, pieces, routed = {}, {}, {}
    store, storeLabel, heard, storeAt = nil, nil, nil, -1e9
    saved, savedSpec, asked = nil, nil, true
end

function Character.init()
    last, lastSpec, stores = load()
    saved, savedSpec, asked = nil, nil, true
    require("rpcchan").on("chr", function(f)
        if UE.IsClient() and type(f.k) == "string" and f.k:match("^%x+$") and #f.k <= 16 then
            heard = { k = f.k, l = (f.l or ""):sub(1, 80) }
        end
    end)
    -- A guest's Escape: the host's game closes this menu itself (it is the
    -- pawn's "UI ESC MENU"); a guest's has no Escape of its own for it.
    pcall(function()
        require("input").bind("ESCAPE", "character screen (guest)", function()
            if UE.IsClient() then Character.escape() end
        end)
    end)
    local n = 0
    for _ in pairs(stores) do n = n + 1 end
    if last or n > 0 then
        Log.info("character: a character kept for %d store(s), the last one made %s (pause menu: Character, or F4)",
                 n, last and ((last.m or ""):match("([^/%.]+)$") or "character") or "none")
    end
end

--- The same route for something else a guest says once in a while (the
--- store's new name, uimachines.lua): fn(pc full name, the rest) on the host.
function Character.onName(prefix, fn) routes[prefix] = fn end

--- Guest: one name to the host on that route.
function Character.sendName(prefix, s)
    local pc = UE.GetPlayerController()
    if not UE.alive(pc) or #prefix + #s > 1000 then return false end
    return pcall(function() pc:ServerNotifyLoadedWorld(FName(prefix .. s)) end)
end

-- For the tests.
Character._wear = wear
Character._load = load
Character._inbox = function() return inbox end
Character._setFile = function(path) FILE = path end
Character._reload = function() last, lastSpec, stores = load() unsaved = nil end
Character._enter = enter
Character._keyOf = keyOf
Character._choose = function() return Character.choose() end
Character._now = function() return store, saved, asked end

return Character
