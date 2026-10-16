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
    it again) and is how that player looks to everyone, in every game.

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

local saved = nil              -- my look, from the file
local savedSpec = nil          -- the choices it was made from
local asked = false            -- the first-time screen has been shown (kept in the file)
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

local function load()
    local ok, fh = pcall(io.open, FILE, "r")
    if not ok or not fh then return nil, nil, false end
    local fields = {}
    for line in fh:lines() do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then fields[k] = v end
    end
    fh:close()
    local look = nil
    if (fields.m or "") ~= "" then
        look = {}
        for _, k in ipairs(LOOK_KEYS) do if fields[k] then look[k] = fields[k] end end
    end
    return look, Creator.fromFields(fields), fields.asked == "1" or look ~= nil
end

local function save()
    local ok, fh = pcall(io.open, FILE, "w")
    if not ok or not fh then return false end
    fh:write("# Rewind Together: what you look like to the other players.\n")
    fh:write("# Change it in game: the pause menu's Character, or F4.\n")
    local fields = { asked = asked and "1" or "0" }
    if saved then for _, k in ipairs(LOOK_KEYS) do if saved[k] then fields[k] = saved[k] end end end
    if savedSpec then Creator.toFields(savedSpec, fields) end
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        fh:write(k, "=", (tostring(fields[k]):gsub("[\r\n]", " ")), "\n")
    end
    fh:close()
    return true
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
    local spec = savedSpec or Creator.random()
    local ok = Screen.open(spec, function(look, made)
        wear(look, made)
        tell(UE.IsStandalone() and "saved - this is how your friends will see you"
             or "this is how everyone sees you now", 5)
    end, function()
        if not asked then asked = true save() end
    end)
    if ok and not asked then asked = true save() end
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
    save()
    tell("character choice cleared - the host picks how you look again")
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

function Character.tick(now)
    hook()
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
    -- The first time: the screen by itself, once the store is up.
    if not asked and not Screen.isOpen() and (now - pawnSince) > FIRST_WAIT and freeToOpen() then
        Log.info("character: first time here - the character screen")
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
    local lines = { ("Character: %s; picked %d, sent %d, received %d, host's own applied %d"):format(
        saved and ("chosen (" .. ((saved.m or ""):match("([^/%.]+)$") or "?") .. ")")
        or "not chosen (the host picks)", stats.picked, stats.sent, stats.received, stats.applied) }
    for _, l in ipairs(Screen.report()) do lines[#lines + 1] = l end
    return lines
end

--- A new world: send again, apply again (what was chosen is kept).
function Character.reset()
    Screen.reset()
    sends, sentAt, appliedHost, pawnSince, openAt = 0, nil, nil, nil, nil
    inbox, pieces, routed = {}, {}, {}
end

function Character.init()
    saved, savedSpec, asked = load()
    -- A guest's Escape: the host's game closes this menu itself (it is the
    -- pawn's "UI ESC MENU"); a guest's has no Escape of its own for it.
    pcall(function()
        require("input").bind("ESCAPE", "character screen (guest)", function()
            if UE.IsClient() then Character.escape() end
        end)
    end)
    if saved then Log.info("character: you look like your chosen %s (pause menu: Character, or F4)",
                           (saved.m or ""):match("([^/%.]+)$") or "character") end
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

return Character
