--[[
    Rewind Together - crash breadcrumbs and config sanity

    TWO JOBS, both of them "stop a mistake turning into a support ticket".

    1. CRASH BREADCRUMBS
    --------------------
    Some of what this mod does can take the game down in native code, where
    pcall is no help at all - it traps Lua errors, not memory faults. Two have
    actually happened: constructing a render component on a live pawn (which is
    why SafeMode exists), and calling a GameMode login function with a
    controller the engine was freeing.

    A crash cannot be caught. It can, however, be *observed after the fact*: if
    the mod wrote down that it was about to do something risky and never wrote
    down that it finished, then the thing it was doing is what killed the
    process. So each risky operation drops a breadcrumb file before it starts
    and deletes it when it returns. A breadcrumb still sitting there at the
    next launch means the last run died inside that operation - so it is
    switched off, permanently, with an explanation.

    That last part is the whole point. The people playing this are not going to
    read a log. Without it they relaunch, hit the identical crash, and conclude
    the mod is broken. With it the game comes up working and tells them which
    cosmetic feature it turned off and how to turn it back on.

    2. CONFIG SANITY
    ----------------
    config.lua is hand-edited by non-programmers, and almost every way of
    getting it wrong currently fails silently: a SteamID pasted with a trailing
    space never matches, PeerSteamIds written as a string instead of a table
    makes the peer loop iterate nothing, a mistyped key name binds no key. All
    of those look exactly like "the mod does not work".

    So the config is checked once at startup and, where it can be, repaired in
    memory - always saying what it did. Nothing here edits the user's file.
]]

local Log = require("log")

local Safety = {}

-- Both live next to RewindTogether.log, in the game's working directory.
local BREADCRUMB = "RewindTogether-inprogress.txt"
local DISABLED   = "RewindTogether-disabled.txt"

local blocked   = {}      -- operation name -> reason it is off
local crashedOn = nil     -- what the previous run died inside, if anything
local failures  = {}      -- operation name -> consecutive Lua failures

-- An operation that throws this many times running is not going to start
-- working on the next tick.
--
-- THIS EXISTS BECAUSE THE FIRST VERSION ONLY HANDLED CRASHES. A crash leaves a
-- breadcrumb and gets retired; a Lua ERROR is caught by the pcall below,
-- logged, and retried on the very next tick - forever. Overlay creation failed
-- that way and wrote 15,000 stack traces and 18 MB of log in one session, each
-- one flushed to disk, on a thread the game is waiting for. Failing safely is
-- not the same as failing quietly, and neither is the same as failing
-- repeatedly.
local MAX_FAILURES = 3

--------------------------------------------------------------------------
-- Breadcrumbs
--------------------------------------------------------------------------

local function readLines(path)
    local out = {}
    local ok, fh = pcall(io.open, path, "r")
    if not (ok and fh) then return out end
    -- Not reassigning the loop variable: Lua 5.4 allows it and 5.5 makes
    -- generic-for variables const, and UE4SS's Lua version is not ours to pin.
    for raw in fh:lines() do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then out[#out + 1] = line end
    end
    fh:close()
    return out
end

local function appendLine(path, text)
    local ok, fh = pcall(io.open, path, "a")
    if not (ok and fh) then return false end
    fh:write(text .. "\n")
    fh:close()
    return true
end

--- Read what happened last time. Call once, before anything risky runs.
function Safety.init()
    for _, op in ipairs(readLines(DISABLED)) do
        blocked[op] = "it crashed the game on a previous run"
    end

    local pending = readLines(BREADCRUMB)
    os.remove(BREADCRUMB)

    if #pending > 0 then
        crashedOn = pending[1]
        if not blocked[crashedOn] then
            blocked[crashedOn] = "it crashed the game on the previous run"
            appendLine(DISABLED, crashedOn)
        end
    end

    return crashedOn
end

--- Say what was turned off and why. Loud, because it is the difference
--- between "the mod fixed itself" and "half of it silently stopped working".
function Safety.report()
    if crashedOn then
        Log.error("=====================================================")
        Log.error(" The game crashed last time during:")
        Log.error("   %s", crashedOn)
        Log.error("")
        Log.error(" That part is now switched OFF so it cannot do it again.")
        Log.error(" Everything else is running normally.")
        Log.error("")
        Log.error(" Type  rt.safety        to see what is off, or")
        Log.error("       rt.safety reset  to try it again after an update.")
        Log.error("=====================================================")
    elseif next(blocked) then
        Log.warn("Some features are off after an earlier crash - see rt.safety")
    end
end

--- Is this operation switched off?
function Safety.isBlocked(op)
    return blocked[op] ~= nil
end

function Safety.blockedList()
    local out = {}
    for op, why in pairs(blocked) do out[#out + 1] = { op = op, why = why } end
    table.sort(out, function(a, b) return a.op < b.op end)
    return out
end

--- Forget every block, so a risky feature gets another chance.
function Safety.reset()
    local n = 0
    for _ in pairs(blocked) do n = n + 1 end
    blocked, crashedOn, failures = {}, nil, {}
    os.remove(DISABLED)
    os.remove(BREADCRUMB)
    return n
end

--- Run something that might take the process down.
---
--- Returns (ran, result): `ran` is false when the operation is switched off,
--- which is deliberately distinct from an operation that ran and returned nil.
--- The breadcrumb is written and closed before fn is called, so it survives a
--- process that never gets to run another line.
function Safety.guard(op, fn, ...)
    if blocked[op] then return false, nil end

    local ok, fh = pcall(io.open, BREADCRUMB, "w")
    if ok and fh then
        fh:write(op .. "\n")
        fh:flush()
        fh:close()
    end

    local success, result = pcall(fn, ...)

    os.remove(BREADCRUMB)

    if not success then
        failures[op] = (failures[op] or 0) + 1

        if failures[op] >= MAX_FAILURES then
            blocked[op] = ("it failed %d times in a row"):format(failures[op])
            appendLine(DISABLED, op)
            Log.error("=====================================================")
            Log.error(" Giving up on:")
            Log.error("   %s", op)
            Log.error("")
            Log.error(" It failed %d times running:", failures[op])
            Log.error("   %s", tostring(result))
            Log.error("")
            Log.error(" Switched off so it cannot keep retrying. Everything")
            Log.error(" else is unaffected.  rt.safety reset  to try again.")
            Log.error("=====================================================")
        else
            Log.error("%s failed (%d/%d): %s", op, failures[op], MAX_FAILURES,
                      tostring(result))
        end
        return true, nil
    end

    -- Worked. Forget any earlier stumbles so a transient failure during level
    -- travel cannot accumulate across a whole session into a false positive.
    failures[op] = nil
    return true, result
end

--------------------------------------------------------------------------
-- Config sanity
--------------------------------------------------------------------------

local problems = {}

local function note(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    problems[#problems + 1] = ok and s or tostring(fmt)
end

local function clampNumber(cfg, key, low, high, default)
    local v = cfg[key]
    if type(v) ~= "number" then
        note("Config.%s should be a number - using %s", key, tostring(default))
        cfg[key] = default
        return
    end
    if v < low or v > high then
        local fixed = math.max(low, math.min(high, v))
        note("Config.%s was %s, which is outside %s-%s - using %s",
             key, tostring(v), tostring(low), tostring(high), tostring(fixed))
        cfg[key] = fixed
    end
end

--- A SteamID64 is exactly 17 digits. Anything else in PeerSteamIds is a
--- typo, and a typo here is invisible: the hello goes to a Steam account that
--- does not exist and nothing anywhere says so.
local function looksLikeSteamId(s)
    return type(s) == "string" and s:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") ~= nil
end

local function checkPeerIds(cfg, myId)
    local raw = cfg.PeerSteamIds

    -- The single commonest edit mistake: quotes instead of braces.
    if type(raw) == "string" then
        note("Config.PeerSteamIds is a single ID in quotes - it needs to be a " ..
             "list: { \"%s\" }. Treating it as one anyway.", raw)
        raw = { raw }
    end

    if type(raw) ~= "table" then
        cfg.PeerSteamIds = {}
        return
    end

    local cleaned = {}
    for _, entry in ipairs(raw) do
        local id = tostring(entry):gsub("%s", "")
        if id == "" then
            -- Empty slot left behind by an edit; nothing to say about it.
        elseif not looksLikeSteamId(id) then
            note("Config.PeerSteamIds contains \"%s\", which is not a SteamID64 " ..
                 "(those are exactly 17 digits). Your friend gets theirs from rt.id.",
                 tostring(entry))
        elseif myId and id == myId then
            note("Config.PeerSteamIds contains your OWN Steam ID - that entry " ..
                 "does nothing. It wants your FRIEND's ID.")
        else
            cleaned[#cleaned + 1] = id
        end
    end
    cfg.PeerSteamIds = cleaned
end

--- Check and, where possible, repair the configuration in memory.
--- Never writes to config.lua - the user's file is theirs.
function Safety.checkConfig(cfg, myId)
    problems = {}

    clampNumber(cfg, "MaxPlayers",              2, 16,    4)
    clampNumber(cfg, "StateSyncHz",             1, 30,    4)
    clampNumber(cfg, "P2PChannel",              0, 255,   41)
    clampNumber(cfg, "PropNetUpdateFrequency",  1, 60,    10)
    clampNumber(cfg, "PawnNetUpdateFrequency",  1, 100,   30)
    clampNumber(cfg, "JoinOnLoadDelay",         0, 120,   3.0)
    clampNumber(cfg, "AutoJoinDelay",           0, 300,   12)
    clampNumber(cfg, "NametagMaxDistance",    100, 100000, 3000.0)

    -- The port is a measured fact on this build, not a preference: it comes
    -- from the packaged DefaultEngine.ini and cannot be moved from here. A
    -- previous version changed it on theory and broke joining outright.
    if type(cfg.Port) ~= "number" or cfg.Port < 1 or cfg.Port > 65535 then
        note("Config.Port must be a number between 1 and 65535 - using 27015")
        cfg.Port = 27015
    elseif cfg.Port ~= 27015 then
        note("Config.Port is %s, but this game's listen server always binds " ..
             "27015 - the port is baked into the packaged config and cannot be " ..
             "changed. Joining will fail. Set it back to 27015.", tostring(cfg.Port))
    end

    if cfg.Transport ~= "ip" then
        note("Config.Transport is \"%s\". Only \"ip\" works on this build - the " ..
             "Steam relay driver reports itself unavailable and the engine " ..
             "silently falls back to IP anyway. Using \"ip\".",
             tostring(cfg.Transport))
        cfg.Transport = "ip"
    end

    checkPeerIds(cfg, myId)

    -- JoinTarget: whitespace here is invisible and fatal.
    if type(cfg.JoinTarget) == "string" then
        local trimmed = cfg.JoinTarget:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= cfg.JoinTarget then
            note("Config.JoinTarget had spaces around it - trimmed to \"%s\"", trimmed)
            cfg.JoinTarget = trimmed
        end
        if trimmed:match("^%d+$") then
            note("Config.JoinTarget looks like a Steam ID. Friends cannot join " ..
                 "by Steam ID on this build - put their IP address there instead " ..
                 "(they get it from CHECK CONNECTION.bat).")
        end
    else
        cfg.JoinTarget = ""
    end

    if cfg.JoinOnLoad and cfg.JoinTarget == "" then
        note("Config.JoinOnLoad is on but Config.JoinTarget is empty, so there " ..
             "is nothing to join. Put your friend's IP in JoinTarget.")
    end

    -- Absent means the default, not "off". A config.lua written before this
    -- option existed must still get guest interaction forwarding, for the same
    -- reason Config.AutoSpawnGuestPawns is checked with == false: carrying an
    -- older file across an upgrade should never quietly undo a fix.
    if cfg.GuestInteractKey == nil then cfg.GuestInteractKey = "E" end

    -- Keybinds. A mistyped name binds nothing and says nothing.
    local function checkKey(label, keyName)
        if keyName == "" then return end          -- deliberately unbound
        if type(keyName) ~= "string" then
            note("%s is not a key name - that action has no key.", label)
        elseif type(Key) == "table" and Key[keyName] == nil then
            note("%s is \"%s\", which UE4SS does not know. Use a name like " ..
                 "E, F5, F7, TAB or NUM_ONE.", label, tostring(keyName))
        end
    end

    if type(cfg.Keys) == "table" then
        for action, keyName in pairs(cfg.Keys) do
            checkKey("Config.Keys." .. tostring(action), keyName)
        end
    end
    checkKey("Config.GuestInteractKey", cfg.GuestInteractKey)

    -- Config.SyncedState is no longer read (1.7.0 moved the list into
    -- sync.lua, with names taken off the game), so an old config.lua that
    -- still carries one is harmless and not worth a warning.

    if ({ error = true, warn = true, info = true, debug = true })[cfg.LogLevel] == nil then
        note("Config.LogLevel is \"%s\" - use error, warn, info or debug. " ..
             "Using info.", tostring(cfg.LogLevel))
        cfg.LogLevel = "info"
    end

    return problems
end

--- Print whatever checkConfig found. Silent when the config is clean.
function Safety.reportConfig()
    if #problems == 0 then return end
    Log.warn("=====================================================")
    Log.warn(" Your config.lua needs a look (%d thing(s)):", #problems)
    for _, p in ipairs(problems) do
        Log.warn("   - %s", p)
    end
    Log.warn("")
    Log.warn(" The mod has worked around these for this session. Fix the")
    Log.warn(" file to make it stick:")
    Log.warn("   ...\\Binaries\\Win64\\ue4ss\\Mods\\RewindTogether\\Scripts\\config.lua")
    Log.warn("=====================================================")
end

function Safety.configProblems()
    return problems
end

return Safety
