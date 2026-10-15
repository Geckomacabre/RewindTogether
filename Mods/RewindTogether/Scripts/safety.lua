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
    process. So the mod keeps a small record on disk of what it is doing right
    now - which part of the tick is running, which risky operations are in
    flight, which feature is on probation - and the next launch reads what the
    last run was doing when it stopped. The operation that was in flight is
    switched off, permanently, with an explanation.

    That last part is the whole point. The people playing this are not going to
    read a log. Without it they relaunch, hit the identical crash, and conclude
    the mod is broken. With it the game comes up working and tells them which
    cosmetic feature it turned off and how to turn it back on.

    WHAT THE FIRST VERSION GOT WRONG, measured on two copies of the game on one PC: a guest
    crashed inside a guarded operation (giving the host a body), and the next
    launch switched off the HUD stand-in instead. Both copies run in the same
    folder and shared one breadcrumb file; the host went on running guarded
    operations, and each one deleted the file on its way out. Only the HUD
    stand-in's probation file survived, so it took the blame. A nested guard
    did the same to its outer one in a single copy. Now each running copy has
    its own record, guards nest, and a feature on probation is only blamed when
    nothing more specific was in flight.

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
local DISABLED    = "RewindTogether-disabled.txt"
-- What this copy of the game is doing right now (THE RECORD, below). One per
-- running copy: a host and a guest started on one PC share the folder, and
-- the single shared breadcrumb of earlier builds is how a guest's crash came to be pinned
-- on the wrong feature.
local RECORD      = "RewindTogether-inflight.%d.txt"
local SLOTS       = 4
-- A record nobody has written for this long belongs to a copy that is not
-- running any more. A running copy writes one at least every tick (ten a
-- second); a crashed one takes far longer than this to be started again.
local STALE_AFTER = 10
-- Earlier builds' breadcrumbs: honoured once after an update, then removed.
local OLD_BREADCRUMB = "RewindTogether-inprogress.txt"
local OLD_PROBATION  = "RewindTogether-probation.txt"

--- The phase between ticks: the engine is running, none of this mod's Lua is.
Safety.IDLE = "idle (between ticks)"

local blocked   = {}      -- operation name -> reason it is off
local crashedOn = nil     -- the operation the previous run died inside, if one
local crashedIn = nil     -- else the tick phase it died in, when that says something
local failures  = {}      -- operation name -> consecutive Lua failures

local token     = nil     -- this process: a hot reload keeps it, a new launch does not
local slot      = nil     -- which record is ours
local recordFh  = nil
local phase     = nil     -- the part of the tick running now
local guards    = {}      -- risky operations in flight, outermost first
local onProbation = nil   -- the feature on probation (Safety.probation)
local probationPhases = {}   -- phase -> true: where that feature's own code runs
local reloaded  = false   -- our record was left by this same process: a hot reload
local written   = 0       -- the longest record written into our file so far
local pid       = nil     -- this process's id, once native.lua can say (Safety.setPid)
local closedWhy = nil     -- set as this Lua state closes in order (see THE RECORD)
local closer    = nil     -- the finalizer that sets it
local epoch     = 0       -- which init() a finalizer belongs to
local pending   = {}      -- uncertain verdicts waiting for Safety.settle
local orphans   = {}      -- fresh records of other copies: running, or dead seconds ago
local cleanLast = nil     -- why the last run's record was found not to be a crash

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
-- The record
--------------------------------------------------------------------------
--[[
    One small text file per running copy, rewritten in place and flushed every
    time what is in flight changes, through a handle kept open - so it is on
    disk before the next line of Lua runs, and costs a write rather than the
    create-and-delete earlier builds paid around every guarded call:

        rt-inflight 1
        token 1f2a40c80-1f2a4d740     this process (see processToken)
        pid 37636                     its id, once RewindNative.dll has said it
        beat 1760480000               os.time() of the last write
        phase Bodies.tick             the part of the tick running
        probation <op>                a feature on probation, and the phases
        probation-phase Hud.tick      its own code runs in
        guard <op>                    risky operations in flight, outermost first
        closed <why>                  this Lua state was closed in order
        end

    Which file is ours: the one this process wrote before a hot reload (same
    token), or else the first one no running copy is writing to. A copy that
    crashed stops writing, so when it is started again it takes its own record
    back and reads what it was doing; a copy still running keeps its record
    fresh and is left alone.

    A record says what the mod was doing when its run stopped, not why it
    stopped. A crash, a closed window, Steam's Stop and a killed process all
    leave the same one - so what it says about a risky operation in flight is
    taken as it is (a guard is only ever left open by a run that died inside
    it), and what it says about anything less certain waits for two more
    witnesses: "closed", written by a finalizer as this Lua state is closed in
    order, and the crash report the engine writes before a crashing process
    dies, which RewindNative.dll can look for (Safety.settle).
]]

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

--- The same in every Lua state of this process and different in the next
--- process: the addresses of two engine objects that live as long as it does.
--- A UE4SS hot reload throws the Lua state away and keeps the process, and
--- must not read like a crash. nil when the engine cannot be asked.
local function processToken()
    local parts = {}
    for _, path in ipairs({ "/Script/CoreUObject.Default__Object",
                            "/Script/Engine.Default__GameplayStatics" }) do
        local ok, addr = pcall(function()
            local o = StaticFindObject(path)
            return o and o:GetAddress()
        end)
        if not (ok and math.type(addr) == "integer" and addr ~= 0) then return nil end
        parts[#parts + 1] = ("%x"):format(addr)
    end
    return table.concat(parts, "-")
end

local function writeRecord()
    if not recordFh then return end
    local lines = { "rt-inflight 1", "token " .. (token or "-") }
    if pid then lines[#lines + 1] = "pid " .. pid end
    lines[#lines + 1] = "beat " .. os.time()
    lines[#lines + 1] = "phase " .. (phase or "-")
    if onProbation then
        lines[#lines + 1] = "probation " .. onProbation
        for p in pairs(probationPhases) do lines[#lines + 1] = "probation-phase " .. p end
    end
    for _, op in ipairs(guards) do lines[#lines + 1] = "guard " .. op end
    if closedWhy then lines[#lines + 1] = "closed " .. closedWhy end
    lines[#lines + 1] = "end\n"
    local text = table.concat(lines, "\n")
    -- Blank out what a longer earlier record left after "end" (never read,
    -- but confusing to a person reading the file).
    if #text < written then text = text .. (" "):rep(written - #text) end
    written = math.max(written, #text)
    pcall(function()
        recordFh:seek("set", 0)
        recordFh:write(text)
        recordFh:flush()
    end)
end

--- A record as written above, or nil (none, or not finished).
local function readRecord(path)
    local ok, fh = pcall(io.open, path, "r")
    if not (ok and fh) then return nil end
    local rec = { guards = {}, probationPhases = {} }
    local complete = false
    for raw in fh:lines() do
        local line = raw:gsub("%s+$", "")
        if line == "end" then
            complete = true
            break
        end
        local key, value = line:match("^(%S+) (.+)$")
        if key == "token" and value ~= "-" then rec.token = value
        elseif key == "pid" then rec.pid = math.tointeger(tonumber(value))
        elseif key == "closed" then rec.closed = value
        elseif key == "beat" then rec.beat = math.tointeger(tonumber(value))
        elseif key == "phase" and value ~= "-" then rec.phase = value
        elseif key == "probation" then rec.probation = value
        elseif key == "probation-phase" then rec.probationPhases[value] = true
        elseif key == "guard" then rec.guards[#rec.guards + 1] = value
        end
    end
    fh:close()
    return complete and rec or nil
end

--- What the run that left `rec` died of, judged by what it was doing:
---   * a risky operation in flight: that one - the innermost, if they nested;
---   * otherwise, the feature on probation, but only if the engine was running
---     rather than this mod's Lua (between ticks), or that feature's own code
---     was: it runs inside the engine's frame, where nothing else of ours does;
---   * otherwise the tick phase, reported with nothing switched off. A crash in
---     one module's tick says nothing about a feature that happened to be on
---     probation at the time - which is exactly the mistake the first version made.
--- Returns the operation to switch off, or nil and the phase to report, and
--- whether that is certain. Only a guard in flight is: the rest is also what
--- a closed window or a killed process leaves behind (Safety.settle).
local function blameOf(rec)
    if #rec.guards > 0 then return rec.guards[#rec.guards], nil, true end
    local outside = rec.phase == nil or rec.phase == Safety.IDLE
    if rec.probation and (outside or rec.probationPhases[rec.phase]) then
        return rec.probation, nil, false
    end
    if outside then return nil, nil, true end    -- nothing to blame either way
    return nil, rec.phase, false
end

local function blame(op, inPhase)
    if op then
        crashedOn = crashedOn or op
        if not blocked[op] then
            blocked[op] = "it crashed the game on the previous run"
            appendLine(DISABLED, op)
        end
    elseif inPhase then
        crashedIn = crashedIn or inPhase
    end
end

--- One ended run's record: blamed at once when that is certain, otherwise
--- kept for Safety.settle to ask the crash reports.
local function judge(rec)
    local op, inPhase, certain = blameOf(rec)
    if certain then
        blame(op, inPhase)
    else
        pending[#pending + 1] = { op = op, phase = inPhase, beat = rec.beat, pid = rec.pid,
                                  closed = rec.closed }
    end
end

--- Read what happened last time. Call once, before anything risky runs.
function Safety.init()
    for _, op in ipairs(readLines(DISABLED)) do
        blocked[op] = "it crashed the game on a previous run"
    end

    if recordFh then pcall(function() recordFh:close() end) end
    recordFh, crashedOn, crashedIn = nil, nil, nil
    phase, guards, onProbation, probationPhases = nil, {}, nil, {}
    pid, closedWhy, pending, orphans, cleanLast = nil, nil, {}, {}, nil
    epoch = epoch + 1

    -- Every record nobody writes any more belongs to a run that has ended:
    -- each is judged once, then cleared (the one this copy takes over is
    -- rewritten below). One still being written is a copy that is running -
    -- or one killed or crashed seconds ago and started straight again, which
    -- Safety.settle tells apart once RewindNative can say whether its process
    -- is alive. Measured: a killed copy relaunched by Steam started its mod 7 s
    -- after the kill, inside the 10 s a record counts as fresh.
    token = processToken()
    local now = os.time()
    local own, free, ended = nil, nil, {}
    for n = 1, SLOTS do
        local rec = readRecord(RECORD:format(n))
        if rec and token and rec.token == token then
            own = own or n                   -- this process, before a hot reload
        elseif rec == nil then
            free = free or n
        elseif now - (rec.beat or 0) > STALE_AFTER then
            judge(rec)
            ended[#ended + 1] = n
            free = free or n
        else
            orphans[#orphans + 1] = { slot = n, rec = rec }
        end
    end
    slot = own or free
    reloaded = own ~= nil
    for _, n in ipairs(ended) do
        if n ~= slot then os.remove(RECORD:format(n)) end
    end

    -- An earlier build, after an update: its breadcrumb named the operation in flight. Its
    -- probation file alone said nothing about what crashed (see the header).
    local old = readLines(OLD_BREADCRUMB)[1]
    os.remove(OLD_BREADCRUMB)
    os.remove(OLD_PROBATION)
    if old and not (crashedOn or crashedIn or #pending > 0) then blame(old, nil) end

    if slot then
        -- Binary: one byte on disk per character, so the padding above fits.
        local ok, fh = pcall(io.open, RECORD:format(slot), "wb")
        if ok and fh then recordFh, written = fh, 0 end
    end
    writeRecord()

    -- Armed after the record is open, on purpose: lua_close runs finalizers
    -- newest first, so this one still finds the file open. A crash runs no
    -- finalizer; a UE4SS hot reload does (and is told apart by the token).
    local mine = epoch
    closer = setmetatable({}, { __gc = function()
        if mine == epoch then Safety.closed("its Lua state was closed") end
    end })
    return crashedOn
end

--- Decide what init() could not, with RewindNative's help (native.lua):
--- `pidAlive(pid)` says whether a process is a running copy of the game, and
--- `crashesSince(t, pid)` counts the crash reports the engine wrote since t
--- about that process. Either may answer nil, and either may be missing.
---
--- First, a record that still looked fresh and whose process is gone is a
--- run that has ended after all, and is judged like the rest. Then each run
--- whose record was uncertain (a feature on probation, or a tick phase, but
--- no operation in flight):
---   * a crash report since its last write: it crashed, blamed as judged;
---   * none: a closed window, Steam's Stop, a killed process - not a crash;
---   * nobody can say: a record its Lua state closed in order is not a
---     crash, anything else is blamed as before (better a feature off
---     than the same crash at every launch).
--- Runs before anything risky - main.lua calls it once RewindNative is up;
--- report() settles without it if nobody did.
function Safety.settle(crashesSince, pidAlive)
    local fresh = orphans
    orphans = {}
    for _, o in ipairs(fresh) do
        local alive = nil
        if pidAlive and o.rec.pid then
            local ok, a = pcall(pidAlive, o.rec.pid)
            if ok then alive = a end
        end
        if alive == false then
            judge(o.rec)
            os.remove(RECORD:format(o.slot))
        end
    end

    local list = pending
    pending = {}
    for _, p in ipairs(list) do
        local reports = nil
        if crashesSince and p.beat then
            local ok, n = pcall(crashesSince, p.beat - 5, p.pid)
            if ok and math.type(n) == "integer" and n >= 0 then reports = n end
        end
        if reports == 0 or (reports == nil and p.closed) then
            cleanLast = (reports == 0) and "the engine wrote no crash report for it"
                        or ("it was closed in order (" .. p.closed .. ")")
        else
            blame(p.op, p.phase)
        end
    end
end

--- This process's id (native.lua), into the record: a crash report names the
--- process it is about, and two copies of the game share the Crashes folder.
function Safety.setPid(id)
    if math.type(id) ~= "integer" or id <= 0 or id == pid then return end
    pid = id
    writeRecord()
end

--- The record says this Lua state is closing in order. Nothing of this mod
--- runs after it - but the engine still does, so a crash report written
--- later still counts (Safety.settle).
function Safety.closed(why)
    closedWhy = tostring(why or "closed")
    writeRecord()
end

--- Say what was turned off and why. Loud, because it is the difference
--- between "the mod fixed itself" and "half of it silently stopped working".
function Safety.report()
    if #pending > 0 or #orphans > 0 then Safety.settle(nil, nil) end
    if cleanLast then
        Log.info("safety: the last run stopped without crashing (%s) - nothing switched off",
                 cleanLast)
    end
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
    elseif crashedIn then
        Log.warn("=====================================================")
        Log.warn(" The game crashed last time while Rewind Together was")
        Log.warn(" running: %s", crashedIn)
        Log.warn("")
        Log.warn(" Nothing risky of its own was in flight, so nothing has")
        Log.warn(" been switched off. If it happens again, rt.safety shows")
        Log.warn(" this - pass it on to whoever made the mod.")
        Log.warn("=====================================================")
    elseif next(blocked) then
        Log.warn("Some features are off after an earlier crash - see rt.safety")
    end
    if reloaded then
        Log.info("safety: carried on from this game's previous Lua state (a UE4SS hot " ..
                 "reload) - that is not a crash")
    end
    if not recordFh then
        Log.warn("safety: no crash record could be kept (%s) - a crash will not be " ..
                 "traced to its cause", slot and "the folder is not writable"
                 or "every slot is taken by a running copy")
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

--- The tick phase the previous run died in with nothing switched off, or nil.
function Safety.lastCrashPhase() return crashedIn end

--- Which record this copy of the game keeps (1-4), or nil.
function Safety.slot() return slot end

--- Forget every block, so a risky feature gets another chance.
function Safety.reset()
    local n = 0
    for _ in pairs(blocked) do n = n + 1 end
    blocked, crashedOn, crashedIn, failures = {}, nil, nil, {}
    os.remove(DISABLED)
    os.remove(OLD_BREADCRUMB)
    os.remove(OLD_PROBATION)
    return n
end

--- Which part of the tick is running (main.lua, before each module). In the
--- record at once, so a crash in a module's own code is put down to that
--- module - and not to a feature that happens to be on probation.
function Safety.phase(name)
    if name == phase then return end
    phase = name
    writeRecord()
end

--- For a risky feature that stays on once switched on, instead of running
--- once - the guest HUD stand-in (hud.lua). If it is going to take the game
--- down, it does so from whatever the game runs next, not from the call that
--- switched it on, so guard() cannot see it. It goes in the record when it is
--- switched on and comes out with Safety.trusted, once it has been seen
--- working or has been switched off again. A run that dies in between, while
--- the engine was running or while `phases` (where its own code runs) were,
--- retires it, exactly as a guarded call would. Returns false when it is
--- switched off after an earlier crash.
function Safety.probation(op, phases)
    if blocked[op] then return false end
    if onProbation == op then return true end
    onProbation, probationPhases = op, {}
    for _, p in ipairs(phases or {}) do probationPhases[p] = true end
    writeRecord()
    return true
end

function Safety.trusted(op)
    if onProbation ~= op then return end
    onProbation, probationPhases = nil, {}
    writeRecord()
end

--- Run something that might take the process down.
---
--- Returns (ran, result): `ran` is false when the operation is switched off,
--- which is deliberately distinct from an operation that ran and returned nil.
--- The record names it, flushed, before fn is called, so it survives a process
--- that never gets to run another line. Guards nest: an inner one returning
--- puts the outer one back in the record (the first version removed it).
function Safety.guard(op, fn, ...)
    if blocked[op] then return false, nil end

    local depth = #guards
    guards[depth + 1] = op
    writeRecord()

    local success, result = pcall(fn, ...)

    for i = #guards, depth + 1, -1 do guards[i] = nil end
    writeRecord()

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

--- Tests only: what the record holds and how this run started.
function Safety._state()
    local g = {}
    for i, op in ipairs(guards) do g[i] = op end
    return { slot = slot, token = token, phase = phase, guards = g, probation = onProbation,
             crashedOn = crashedOn, crashedIn = crashedIn, reloaded = reloaded,
             pid = pid, closed = closedWhy, pending = #pending, orphans = #orphans,
             cleanLast = cleanLast,
             file = slot and RECORD:format(slot) or nil }
end

--- Tests only: run the finalizer lua_close would run for this Lua state.
function Safety._close()
    local mt = closer and getmetatable(closer)
    if mt and mt.__gc then mt.__gc(closer) end
end

--- Tests only: forget what init() read, as a new Lua state would.
function Safety._forget()
    if recordFh then pcall(function() recordFh:close() end) end
    recordFh = nil
    blocked, crashedOn, crashedIn, failures = {}, nil, nil, {}
    phase, guards, onProbation, probationPhases = nil, {}, nil, {}
    token, slot, reloaded = nil, nil, false
    pid, closedWhy, pending, orphans, cleanLast = nil, nil, {}, {}, nil
    epoch = epoch + 1
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
                 "(they get it from Extras\\CHECK CONNECTION.bat).")
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
